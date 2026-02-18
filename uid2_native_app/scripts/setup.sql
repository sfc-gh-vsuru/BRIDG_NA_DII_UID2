-- ============================================================================
-- UID2 Native App Setup Script
-- Converts Direct Identifying Information (DII) to UID2 tokens
-- ============================================================================

-- Create versioned schema for stateless objects (UDFs, Streamlit)
CREATE OR ALTER VERSIONED SCHEMA APP_SCHEMA;

-- ============================================================================
-- HASH FUNCTION (Pure Python - No external dependencies)
-- This function normalizes and hashes DII without needing UID2 API credentials
-- ============================================================================
CREATE OR REPLACE FUNCTION APP_SCHEMA.hash_dii_for_uid2(
    dii STRING,
    dii_type STRING
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'main'
AS $$
import hashlib
import base64

def normalize_email(email: str) -> str:
    email = email.lower().strip()
    if '@' not in email:
        return email
    local, domain = email.rsplit('@', 1)
    if domain in ('gmail.com', 'googlemail.com'):
        local = local.replace('.', '').split('+')[0]
    return f"{local}@{domain}"

def normalize_phone(phone: str) -> str:
    digits = ''.join(c for c in phone if c.isdigit() or c == '+')
    if not digits.startswith('+'):
        digits = '+1' + digits
    return digits

def main(dii, dii_type):
    try:
        if dii_type.lower() == 'email':
            normalized = normalize_email(dii)
        elif dii_type.lower() == 'phone':
            normalized = normalize_phone(dii)
        else:
            return {'error': f'Invalid dii_type: {dii_type}', 'status': 'error'}
        
        hashed = hashlib.sha256(normalized.encode('utf-8')).digest()
        hash_b64 = base64.b64encode(hashed).decode('utf-8')
        
        return {
            'original_dii': dii,
            'normalized_dii': normalized,
            'dii_type': dii_type,
            'sha256_hash_base64': hash_b64,
            'status': 'success'
        }
    except Exception as e:
        return {'error': str(e), 'status': 'error'}
$$;

-- ============================================================================
-- UID2 CONVERSION FUNCTION (Using Anaconda packages available in Snowflake)
-- This uses the UID2 API directly via HTTP requests
-- Requires x86 warehouse due to native code dependencies in pycryptodome
-- ============================================================================
CREATE OR REPLACE FUNCTION APP_SCHEMA.convert_dii_to_uid2(
    dii STRING,
    dii_type STRING,
    base_url STRING,
    api_key STRING,
    client_secret STRING
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests', 'pycryptodome')
HANDLER = 'main'
AS $$
import hashlib
import base64
import time
import os
import json
import requests
from Crypto.Cipher import AES

def normalize_email(email: str) -> str:
    email = email.lower().strip()
    if '@' not in email:
        return email
    local, domain = email.rsplit('@', 1)
    if domain in ('gmail.com', 'googlemail.com'):
        local = local.replace('.', '').split('+')[0]
    return f"{local}@{domain}"

def normalize_phone(phone: str) -> str:
    digits = ''.join(c for c in phone if c.isdigit() or c == '+')
    if not digits.startswith('+'):
        digits = '+1' + digits
    return digits

def encrypt_request(payload: dict, client_secret: str) -> tuple:
    secret_bytes = base64.b64decode(client_secret)
    nonce = os.urandom(8)
    timestamp = int(time.time() * 1000)
    
    body = json.dumps(payload).encode('utf-8')
    data = timestamp.to_bytes(8, 'big') + nonce + body
    
    cipher = AES.new(secret_bytes, AES.MODE_GCM, nonce=nonce)
    ciphertext, tag = cipher.encrypt_and_digest(data)
    
    envelope = b'\\x01' + nonce + ciphertext + tag
    return base64.b64encode(envelope).decode('utf-8'), timestamp

def decrypt_response(encrypted: str, client_secret: str, nonce: bytes) -> dict:
    secret_bytes = base64.b64decode(client_secret)
    data = base64.b64decode(encrypted)
    
    response_nonce = data[:12]
    ciphertext = data[12:-16]
    tag = data[-16:]
    
    cipher = AES.new(secret_bytes, AES.MODE_GCM, nonce=response_nonce)
    decrypted = cipher.decrypt_and_verify(ciphertext, tag)
    
    return json.loads(decrypted[16:].decode('utf-8'))

def main(dii, dii_type, base_url, api_key, client_secret):
    try:
        if dii_type.lower() == 'email':
            normalized = normalize_email(dii)
            hash_input = hashlib.sha256(normalized.encode('utf-8')).digest()
            hash_b64 = base64.b64encode(hash_input).decode('utf-8')
            payload = {'email_hash': [hash_b64]}
        elif dii_type.lower() == 'phone':
            normalized = normalize_phone(dii)
            hash_input = hashlib.sha256(normalized.encode('utf-8')).digest()
            hash_b64 = base64.b64encode(hash_input).decode('utf-8')
            payload = {'phone_hash': [hash_b64]}
        else:
            return {'error': f'Invalid dii_type: {dii_type}', 'status': 'error'}
        
        encrypted_payload, timestamp = encrypt_request(payload, client_secret)
        
        url = f"{base_url.rstrip('/')}/v2/identity/map"
        headers = {
            'Authorization': f'Bearer {api_key}',
            'Content-Type': 'text/plain'
        }
        
        response = requests.post(url, data=encrypted_payload, headers=headers, timeout=30)
        
        if response.status_code == 200:
            return {
                'raw_response': response.text[:200],
                'normalized_dii': normalized,
                'hash_b64': hash_b64,
                'status': 'api_called',
                'note': 'Full decryption requires uid2-client SDK. Use hash for matching.'
            }
        else:
            return {
                'error': f'API error: {response.status_code} - {response.text[:200]}',
                'status': 'error'
            }
            
    except Exception as e:
        return {'error': str(e), 'status': 'error'}
$$;

-- ============================================================================
-- BATCH CONVERSION TABLE FUNCTION (UDTF)
-- Efficiently process multiple DIIs at once
-- ============================================================================
CREATE OR REPLACE FUNCTION APP_SCHEMA.batch_hash_dii(dii STRING, dii_type STRING)
RETURNS TABLE (
    original_dii STRING,
    normalized_dii STRING,
    dii_type STRING,
    sha256_hash_base64 STRING,
    status STRING
)
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'BatchHashHandler'
AS $$
import hashlib
import base64

class BatchHashHandler:
    def normalize_email(self, email: str) -> str:
        email = email.lower().strip()
        if '@' not in email:
            return email
        local, domain = email.rsplit('@', 1)
        if domain in ('gmail.com', 'googlemail.com'):
            local = local.replace('.', '').split('+')[0]
        return f"{local}@{domain}"
    
    def normalize_phone(self, phone: str) -> str:
        digits = ''.join(c for c in phone if c.isdigit() or c == '+')
        if not digits.startswith('+'):
            digits = '+1' + digits
        return digits
    
    def process(self, dii, dii_type):
        try:
            if dii_type.lower() == 'email':
                normalized = self.normalize_email(dii)
            elif dii_type.lower() == 'phone':
                normalized = self.normalize_phone(dii)
            else:
                yield (dii, '', dii_type, '', f'Invalid type: {dii_type}')
                return
            
            hashed = hashlib.sha256(normalized.encode('utf-8')).digest()
            hash_b64 = base64.b64encode(hashed).decode('utf-8')
            yield (dii, normalized, dii_type, hash_b64, 'success')
        except Exception as e:
            yield (dii, '', dii_type, '', f'Error: {str(e)}')
$$;

-- ============================================================================
-- STREAMLIT APPLICATION
-- Interactive dashboard for DII to UID2 conversion
-- ============================================================================
CREATE OR REPLACE STREAMLIT APP_SCHEMA.uid2_converter_app
    FROM '/streamlit'
    MAIN_FILE = 'streamlit_app.py';

-- ============================================================================
-- APPLICATION ROLE AND GRANTS
-- ============================================================================
CREATE APPLICATION ROLE IF NOT EXISTS app_public;

GRANT USAGE ON SCHEMA APP_SCHEMA TO APPLICATION ROLE app_public;
GRANT USAGE ON FUNCTION APP_SCHEMA.hash_dii_for_uid2(STRING, STRING) TO APPLICATION ROLE app_public;
GRANT USAGE ON FUNCTION APP_SCHEMA.convert_dii_to_uid2(STRING, STRING, STRING, STRING, STRING) TO APPLICATION ROLE app_public;
GRANT USAGE ON FUNCTION APP_SCHEMA.batch_hash_dii(STRING, STRING) TO APPLICATION ROLE app_public;
GRANT USAGE ON STREAMLIT APP_SCHEMA.uid2_converter_app TO APPLICATION ROLE app_public;
