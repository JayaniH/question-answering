import ballerina/http;
import ballerina/io;
import ballerinax/googleapis.sheets;
import ballerina/lang.'float as langFloat;
import ballerina/regex;
import ballerina/log;


// Google Sheets API client configuration parameters
configurable string gsheetsClientID = ?;
configurable string gsheetsClientSecret = ?;
configurable string gsheetsRefreshToken = ?;
configurable string sheetId = ?;
configurable string sheetName = ?;

// OpenAI token
configurable string openAIToken = ?;


type Request record {|
    string question;
|};

type OpenAIEmbeddingPrompt record {
    string model = "text-embedding-ada-002";
    string input;
};

type OpenAICompletionPrompt record {
    string model = "text-davinci-003";
    string prompt;
    float temperature = 0.7;
    int max_tokens = 256;
    float top_p = 1;
    int frequency_penalty = 0;
    int presence_penalty = 0;
};

type OpenAIEmbeddingDataItem record {
    float[] embedding;
    int index;
    string 'object;
};

type OpenAIEmbeddingUsage record {
    int prompt_tokens;
    int total_tokens;
};

type OpenAIEmbeddingResponse record {
    string 'object;
    string model;
    OpenAIEmbeddingDataItem[] data;
    OpenAIEmbeddingUsage usage;
};

type OpenAICompletionChoicesItem record {
    string text;
    int index;
    anydata logprobs;
    string finish_reason;
};

type OpenAICompletionUsage record {
    int prompt_tokens;
    int completion_tokens;
    int total_tokens;
};

type OpenAICompletionResponse record {
    string id;
    string 'object;
    int created;
    string model;
    OpenAICompletionChoicesItem[] choices;
    OpenAICompletionUsage usage;
};


// Configure Google Sheets client
sheets:ConnectionConfig spreadsheetConfig = {
    auth: {
        clientId: gsheetsClientID,
        clientSecret: gsheetsClientSecret,
        refreshUrl: sheets:REFRESH_URL,
        refreshToken: gsheetsRefreshToken
    }
};
sheets:Client spreadsheetClient = check new (spreadsheetConfig);

// Configure OpenAI client
http:Client openAI = check new ("https://api.openai.com");


function countWords(string text) returns int {
    // Count the number of words in a text

    string[] words = regex:split(text, " ");
    return words.length();
}

function cosineSimilarity(float[] vector1, float[] vector2) returns float {
    // Calculate cosine similarity between two vectors

    float dotProduct = 0.0;
    float magnitude1 = 0.0;
    float magnitude2 = 0.0;

    // Compute dot product and magnitudes
    foreach int i in 0 ..< vector1.length(){
        dotProduct += vector1[i] * vector2[i];
        magnitude1 += langFloat:pow(vector1[i], 2);
        magnitude2 += langFloat:pow(vector2[i], 2);
    }

    // Compute cosine similarity
    float magnitudeProduct = langFloat:sqrt(magnitude1) * langFloat:sqrt(magnitude2);
    if (magnitudeProduct == 0.0) {
        return 0.0;
    }
    return dotProduct / magnitudeProduct;
}

function getEmbedding(string text) returns float[]| error{
    // Get embedding vector for text

    OpenAIEmbeddingPrompt input = {
            input: text
        };
    OpenAIEmbeddingResponse embeddingRes = check openAI->post("/v1/embeddings", input, { "Authorization": "Bearer " + openAIToken});

    return embeddingRes.data[0].embedding;
}

function getDocumentSimilarity(string question, map<float[]> doc_embeddings) returns [string,float?][]|error {
    // Get similar documents for a question

    // Get question embedding
    float[] question_embedding = check getEmbedding(question);

    [string,float?][] doc_similarity = [];

    foreach string heading in doc_embeddings.keys() {
        float similarity = cosineSimilarity(<float[]>doc_embeddings[heading], question_embedding);
        doc_similarity.push([heading, similarity]);
    }

    [string,float?][] doc_similarity_sorted = from var item in doc_similarity order by item[1] descending select item;

    return doc_similarity_sorted;
}

function constructPrompt(string question, map<string> documents, map<float[]> doc_embeddings) returns string|error{
    // Construct prompt for question answering using context from the most similar documents

    [string,float?][] document_similarity = check getDocumentSimilarity(question, doc_embeddings);
    string context = "";
    int contextLen = 0;
    int maxLen = 1125; // approx equivalence between word and token count

    foreach [string,float?] item in document_similarity {
        string heading = item[0];
        string content = <string>documents[heading];

        contextLen += countWords(content);
        io:println(contextLen);
        if contextLen > maxLen {
            break;
        }

        context += "\n*" + content;
    }

    string instruction = "Answer the question as truthfully as possible using the provided context, and if the answer is not contained within the text below, say \"I don't know.\"\n\nContext:\n";
    return instruction + context + "\n\n Q: " + question + "\n A:";
}

function generateAnswer(string prompt) returns string|error{
    // Generate answer from the completion model

    OpenAICompletionPrompt prmt = {
        prompt: prompt
    };  
    OpenAICompletionResponse completionRes = check openAI->post("/v1/completions", prmt, { "Authorization": "Bearer " + openAIToken});

    string answer = completionRes.choices[0].text;

    return answer;
}

function loadData(string sheetId, string sheetName = "Sheet1") returns [map<string>, map<float[]>]|error{
    // Load data from the google sheet and compute embeddings

    log:printInfo("Loading data");

    // Fetch the data from the 'heading' and 'content' columns.
    sheets:Range range = check spreadsheetClient->getRange(sheetId, sheetName, "A2:B");

    // Define an empty dictionary for doc embeddings.
    map<string> documents = {};
    
    // Define an empty dictionary for doc embeddings.
    map<float[]> doc_embeddings = {};

    // Iterate through the array of arrays and populate the dictionaries with the content and embeddings for each doc.
    foreach any[] row in range.values {
        string title = <string>row[0];
        string content = <string>row[1];

        documents[title] = content;
        doc_embeddings[title] = check getEmbedding(title + "\n" + content);
    }

    log:printInfo("Loading complete");

    return [documents, doc_embeddings];
    
}

// Load the data and compute the embeddings when the service starts
[map<string>, map<float[]>] [documents, doc_embeddings]= check loadData(sheetId);

service / on new http:Listener(8080) {
    
    resource function post generateAnswer (@http:Payload Request request) returns string {

        // string question = "What is choreo?";
        string question = request.question;

        string|error prompt = constructPrompt(question, documents, doc_embeddings);

        if prompt is error{
            log:printError("Error constructing prompt");
            return "";
        }
        
        log:printInfo(prompt);

        string|error answer = generateAnswer(prompt);

        if answer is error{
            log:printError("Error generating answer");
            return "";
        }

        log:printInfo(answer);

        return answer;
    }
}