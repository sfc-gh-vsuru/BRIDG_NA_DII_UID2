-- ============================================================================
-- UID2 Native App Setup Script
-- Converts Direct Identifying Information (DII) to UID2 tokens
-- 
-- PATTERN: Deferred UDF creation for ARTIFACT_REPOSITORY
-- The uid2-client PyPI UDF cannot be created at install time because the app
-- role lacks SNOWFLAKE.PYPI_REPOSITORY_USER. Instead, a setup procedure is
-- provided that the consumer calls AFTER granting the database role to the app.
--
-- Consumer post-install steps:
--   1. GRANT DATABASE ROLE SNOWFLAKE.PYPI_REPOSITORY_USER TO APPLICATION <app_name>;
--   2. CALL <app_name>.APP_SCHEMA.setup_uid2_sdk();
-- ============================================================================

CREATE OR ALTER VERSIONED SCHEMA APP_SCHEMA;

-- ============================================================================
-- HASH FUNCTION (Pure Python - works immediately, no special grants needed)
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
-- DEFERRED SETUP PROCEDURE
-- Consumer calls this AFTER granting SNOWFLAKE.PYPI_REPOSITORY_USER to the app.
-- This creates the UDF that uses Trade Desk's uid2-client from PyPI.
-- Uses JavaScript to avoid nested quoting issues with EXECUTE IMMEDIATE.
-- ============================================================================
CREATE OR REPLACE PROCEDURE APP_SCHEMA.setup_uid2_sdk()
RETURNS STRING
LANGUAGE JAVASCRIPT
EXECUTE AS OWNER
AS
$$
var python_code = [
    'from uid2_client import IdentityMapClient, IdentityMapInput',
    '',
    'def main(dii, dii_type, base_url, api_key, client_secret):',
    '    try:',
    '        client = IdentityMapClient(base_url, api_key, client_secret)',
    '        if dii_type.lower() == "email":',
    '            identity_input = IdentityMapInput.from_emails([dii])',
    '        elif dii_type.lower() == "phone":',
    '            identity_input = IdentityMapInput.from_phones([dii])',
    '        else:',
    '            return {"error": f"Invalid dii_type: {dii_type}", "status": "error"}',
    '        response = client.generate_identity_map(identity_input)',
    '        if response.mapped_identities:',
    '            first_key = list(response.mapped_identities.keys())[0]',
    '            mapped = response.mapped_identities[first_key]',
    '            return {"raw_uid2": mapped.get_raw_uid(), "bucket_id": mapped.get_bucket_id(), "status": "success"}',
    '        elif response.unmapped_identities:',
    '            first_key = list(response.unmapped_identities.keys())[0]',
    '            unmapped = response.unmapped_identities[first_key]',
    '            return {"error": f"Identity not mapped: {unmapped.get_reason()}", "status": "unmapped"}',
    '        else:',
    '            return {"error": "No response from UID2 API", "status": "error"}',
    '    except Exception as e:',
    '        return {"error": str(e), "status": "error"}'
].join('\n');

var create_sql = `
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
ARTIFACT_REPOSITORY = snowflake.snowpark.pypi_shared_repository
PACKAGES = ('uid2-client')
RESOURCE_CONSTRAINT = (architecture='x86')
EXTERNAL_ACCESS_INTEGRATIONS = (uid2_api_access)
HANDLER = 'main'
AS '` + python_code.replace(/'/g, "''") + `'`;

try {
    snowflake.execute({sqlText: create_sql});
} catch (err) {
    return "ERROR creating UDF: " + err.message;
}

try {
    snowflake.execute({sqlText: "GRANT USAGE ON FUNCTION APP_SCHEMA.convert_dii_to_uid2(STRING, STRING, STRING, STRING, STRING) TO APPLICATION ROLE app_public"});
} catch (err) {
    return "UDF created but GRANT failed: " + err.message;
}

return "UID2 SDK setup complete. convert_dii_to_uid2() is now available using Trade Desk uid2-client from PyPI.";
$$;

-- ============================================================================
-- STATUS CHECK PROCEDURE
-- Lets consumers verify whether the SDK has been set up
-- ============================================================================
CREATE OR REPLACE PROCEDURE APP_SCHEMA.check_uid2_sdk_status()
RETURNS STRING
LANGUAGE SQL
EXECUTE AS OWNER
AS
BEGIN
    LET func_exists BOOLEAN := FALSE;
    SELECT COUNT(*) > 0 INTO :func_exists
    FROM INFORMATION_SCHEMA.FUNCTIONS
    WHERE FUNCTION_NAME = 'CONVERT_DII_TO_UID2'
      AND FUNCTION_SCHEMA = 'APP_SCHEMA';
    
    IF (func_exists) THEN
        RETURN 'READY: convert_dii_to_uid2() is available. You can call it with an x86 warehouse.';
    ELSE
        RETURN 'NOT CONFIGURED: Run these steps:\n1. GRANT DATABASE ROLE SNOWFLAKE.PYPI_REPOSITORY_USER TO APPLICATION <app_name>;\n2. CALL APP_SCHEMA.setup_uid2_sdk();';
    END IF;
END;

-- ============================================================================
-- STREAMLIT APPLICATION
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
GRANT USAGE ON PROCEDURE APP_SCHEMA.setup_uid2_sdk() TO APPLICATION ROLE app_public;
GRANT USAGE ON PROCEDURE APP_SCHEMA.check_uid2_sdk_status() TO APPLICATION ROLE app_public;
GRANT USAGE ON STREAMLIT APP_SCHEMA.uid2_converter_app TO APPLICATION ROLE app_public;
