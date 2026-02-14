import json
import boto3
import os
import urllib.parse
import time
import random
from botocore.exceptions import ClientError
from opensearchpy import OpenSearch, RequestsHttpConnection, AWSV4SignerAuth

# Clients
s3 = boto3.client('s3')
bedrock = boto3.client('bedrock-runtime', region_name='us-east-1')

def retry_with_backoff(func, *args, **kwargs):
    """
    Retries a function if it hits a ThrottlingException.
    Waits 2s, then 4s, then 8s...
    """
    max_retries = 5
    base_delay = 2
    
    for attempt in range(max_retries):
        try:
            return func(*args, **kwargs)
        except ClientError as e:
            error_code = e.response['Error']['Code']
            if error_code == 'ThrottlingException' and attempt < max_retries - 1:
                sleep_time = base_delay * (2 ** attempt) + random.uniform(0, 1)
                print(f"Throttled. Retrying in {sleep_time:.2f} seconds...")
                time.sleep(sleep_time)
            else:
                raise e

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
        
        if not file_content:
            return {'statusCode': 200, 'body': 'File is empty'}

        # TRUNCATE: Limit input to ~15,000 characters to prevent hitting Token Limits
        # (Claude 3 Sonnet context window is large, but your Tier 1 TPM quota might be small)
        if len(file_content) > 15000:
            print("File too large. Truncating to 15,000 characters...")
            file_content = file_content[:15000]

        # 3. Generate Summary with Bedrock (Claude 3 Sonnet)
        prompt = f"Please provide a concise summary of the following document:\n\n{file_content}"
        
        bedrock_body = json.dumps({
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 1000,
            "messages": [
                {"role": "user", "content": prompt}
            ]
        })

        # Wrap the invoke in our retry logic
        def call_bedrock():
            return bedrock.invoke_model(
                modelId='anthropic.claude-3-sonnet-20240229-v1:0',
                body=bedrock_body
            )

        bedrock_resp = retry_with_backoff(call_bedrock)
        
        resp_body = json.loads(bedrock_resp['body'].read())
        summary = resp_body['content'][0]['text']
        print(f"Summary generated successfully: {summary[:50]}...")

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
            'content': file_content[:1000], 
            'summary': summary,
            'timestamp': "2024-01-01" 
        }

        index_name = "summaries"
        if not client.indices.exists(index=index_name):
            client.indices.create(index=index_name)

        client.index(index=index_name, body=document)
        print(f"Document indexed to OpenSearch: {host}")

        return {'statusCode': 200, 'body': json.dumps('Success')}

    except Exception as e:
        print(f"CRITICAL ERROR: {str(e)}")
        # Return 200 to stop S3 from retrying and hammering Bedrock further
        return {'statusCode': 200, 'body': json.dumps(f"Error: {str(e)}")}
