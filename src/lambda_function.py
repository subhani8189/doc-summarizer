import json
import boto3
import os
import urllib.parse
from opensearchpy import OpenSearch, RequestsHttpConnection, AWSV4SignerAuth

# Clients
s3 = boto3.client('s3')
bedrock = boto3.client('bedrock-runtime', region_name='us-east-1')

def handler(event, context):
    print("Received event: " + json.dumps(event, indent=2))

    # 1. Get S3 Object details
    bucket = event['Records'][0]['s3']['bucket']['name']
    key = urllib.parse.unquote_plus(event['Records'][0]['s3']['object']['key'])
    
    print(f"Processing file: {key} from bucket: {bucket}")

    try:
        # 2. Read File Content
        response = s3.get_object(Bucket=bucket, Key=key)
        file_content = response['Body'].read().decode('utf-8')
        
        # Simple check to avoid processing empty files
        if not file_content:
            print("File is empty.")
            return {'statusCode': 200, 'body': 'File is empty'}

        # 3. Generate Summary with Bedrock (Claude 3 Sonnet)
        prompt = f"Please provide a concise summary of the following document:\n\n{file_content}"
        
        bedrock_body = json.dumps({
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 1000,
            "messages": [
                {"role": "user", "content": prompt}
            ]
        })

        bedrock_resp = bedrock.invoke_model(
            modelId='anthropic.claude-3-sonnet-20240229-v1:0',
            body=bedrock_body
        )
        
        resp_body = json.loads(bedrock_resp['body'].read())
        summary = resp_body['content'][0]['text']
        print(f"Summary generated: {summary[:50]}...")

        # 4. Index to OpenSearch Serverless
        host = os.environ['OPENSEARCH_HOST']
        region = 'us-east-1'
        service = 'aoss'
        credentials = boto3.Session().get_credentials()
        auth = AWSV4SignerAuth(credentials, region, service)

        client = OpenSearch(
            hosts=[{'host': host, 'port': 443}],
            http_auth=auth,
            use_ssl=True,
            verify_certs=True,
            connection_class=RequestsHttpConnection,
            pool_maxsize=20
        )

        document = {
            'filename': key,
            'content': file_content[:1000], # Store partial content to save space
            'summary': summary,
            'timestamp': "2024-01-01" 
        }

        # Create index if it doesn't exist
        index_name = "summaries"
        if not client.indices.exists(index=index_name):
            client.indices.create(index=index_name)

        client.index(index=index_name, body=document)
        print(f"Document indexed to OpenSearch: {host}")

        return {
            'statusCode': 200, 
            'body': json.dumps('Success')
        }

    except Exception as e:
        print(f"Error: {str(e)}")
        # Return success (200) even on error so S3 doesn't retry infinitely
        return {
            'statusCode': 200, 
            'body': json.dumps(f"Error processing file: {str(e)}")
        }