# UID2 Native App - DII to UID2 Converter

A Snowflake Native App that converts Direct Identifying Information (DII) such as emails and phone numbers to Unified ID 2.0 (UID2) tokens.

## Overview

This project demonstrates how to integrate the UID2 SDK with Snowflake Native Apps, including:
- Pure Python hash functions for DII normalization
- UID2 API integration via Anaconda packages
- Interactive Streamlit dashboard
- Batch processing capabilities

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                   Streamlit Dashboard                        │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────┐    ┌──────────────────────────┐       │
│  │  hash_dii_for_  │    │  convert_dii_to_uid2     │       │
│  │     uid2()      │    │  (pycryptodome+requests) │       │
│  │  (Pure Python)  │    │  Anaconda packages       │       │
│  └─────────────────┘    └──────────────────────────┘       │
├─────────────────────────────────────────────────────────────┤
│                  Snowflake Native App                        │
│           (Versioned Schema + Application Package)          │
└─────────────────────────────────────────────────────────────┘
```

## Key Findings from Development

### Approach Comparison

| Approach | Status | Notes |
|----------|--------|-------|
| **ARTIFACT_REPOSITORY (PyPI)** | ✅ Works for standalone UDFs | Best for non-Native App use cases. Native Apps don't inherit PYPI_REPOSITORY_USER role. |
| **Wheel Bundling (Stage Imports)** | ❌ Failed | C extensions (bitarray, pycryptodome) require extraction which fails in read-only UDF environment. |
| **Anaconda Packages** | ✅ Works in Native Apps | All uid2_client dependencies (bitarray, pycryptodome, typing-extensions) available in Snowflake's Anaconda channel. |

### Important Discovery

The `uid2-client` Python package cannot be directly used in Native Apps via ARTIFACT_REPOSITORY because:
1. Native Apps run with their own application owner role
2. This role doesn't have PYPI_REPOSITORY_USER database role
3. The grant cannot be applied to application roles

**Solution**: Implement UID2 functionality using available Anaconda packages (pycryptodome, requests) and direct API calls.

## Project Structure

```
uid2_native_app/
├── manifest.yml              # Native App manifest
├── readme.md                 # App readme (shown in Snowsight)
├── scripts/
│   └── setup.sql            # Setup script with UDFs and Streamlit
├── app/
│   ├── streamlit/
│   │   ├── streamlit_app.py # Streamlit dashboard
│   │   └── environment.yml  # Streamlit dependencies
│   └── python/
│       └── uid2_converter.py # Python module (reference)
├── wheels/                   # Downloaded wheel files (for reference)
└── tests/                    # Test files
```

## Quick Start

### Prerequisites

1. Snowflake account with Native Apps enabled
2. Role with permissions to create databases, application packages, and applications
3. For ARTIFACT_REPOSITORY (standalone UDF): PYPI_REPOSITORY_USER database role
4. For full UID2 conversion: UID2 API credentials

### Installation

#### Option 1: Deploy from Source

```sql
-- 1. Create development database
CREATE DATABASE IF NOT EXISTS UID2_NATIVE_APP_DEV;
CREATE SCHEMA IF NOT EXISTS UID2_NATIVE_APP_DEV.DEVELOPMENT;
CREATE STAGE IF NOT EXISTS UID2_NATIVE_APP_DEV.DEVELOPMENT.APP_STAGE DIRECTORY = (ENABLE = TRUE);

-- 2. Upload files (using PUT commands or Snowsight)
-- PUT 'file:///path/to/manifest.yml' @UID2_NATIVE_APP_DEV.DEVELOPMENT.APP_STAGE/ ...

-- 3. Create Application Package
CREATE APPLICATION PACKAGE IF NOT EXISTS UID2_CONVERTER_PKG;
CREATE SCHEMA IF NOT EXISTS UID2_CONVERTER_PKG.STAGE_CONTENT;
CREATE STAGE IF NOT EXISTS UID2_CONVERTER_PKG.STAGE_CONTENT.APP_STAGE;

-- 4. Copy files and register version
COPY FILES INTO @UID2_CONVERTER_PKG.STAGE_CONTENT.APP_STAGE FROM @UID2_NATIVE_APP_DEV.DEVELOPMENT.APP_STAGE/;

ALTER APPLICATION PACKAGE UID2_CONVERTER_PKG
    REGISTER VERSION V1
    USING '@UID2_CONVERTER_PKG.STAGE_CONTENT.APP_STAGE';

-- 5. Create Application
CREATE APPLICATION UID2_CONVERTER_APP
    FROM APPLICATION PACKAGE UID2_CONVERTER_PKG
    USING '@UID2_CONVERTER_PKG.STAGE_CONTENT.APP_STAGE';
```

#### Option 2: Use Standalone UDFs (with ARTIFACT_REPOSITORY)

For use outside Native Apps, the PyPI approach is simpler:

```sql
-- Requires: GRANT DATABASE ROLE SNOWFLAKE.PYPI_REPOSITORY_USER TO ROLE <your_role>;

CREATE WAREHOUSE IF NOT EXISTS UID2_X86_WH 
  WAREHOUSE_SIZE = 'MEDIUM'
  WAREHOUSE_TYPE = 'SNOWPARK-OPTIMIZED'
  RESOURCE_CONSTRAINT = 'MEMORY_16X_X86';

USE WAREHOUSE UID2_X86_WH;

CREATE OR REPLACE FUNCTION convert_dii_to_uid2(
    dii STRING, dii_type STRING, base_url STRING, api_key STRING, client_secret STRING
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
ARTIFACT_REPOSITORY = snowflake.snowpark.pypi_shared_repository
PACKAGES = ('uid2-client')
RESOURCE_CONSTRAINT = (architecture='x86')
HANDLER = 'main'
AS $$
from uid2_client import IdentityMapClient, IdentityMapInput

def main(dii, dii_type, base_url, api_key, client_secret):
    client = IdentityMapClient(base_url, api_key, client_secret)
    identity = IdentityMapInput.from_email(dii) if dii_type == 'email' else IdentityMapInput.from_phone(dii)
    response = client.generate_identity_map([identity])
    if response.mapped_identities:
        mapped = response.mapped_identities[0]
        return {'raw_uid2': mapped.raw_uid, 'bucket_id': mapped.bucket_id, 'status': 'success'}
    return {'error': 'Not mapped', 'status': 'error'}
$$;
```

## Testing

### Test Hash Function (No API Required)

```sql
-- Test email normalization (Gmail removes dots and plus tags)
SELECT 
    result:original_dii::STRING as original,
    result:normalized_dii::STRING as normalized,
    result:sha256_hash_base64::STRING as hash
FROM (
    SELECT UID2_CONVERTER_APP.APP_SCHEMA.hash_dii_for_uid2('Test.User+promo@gmail.com', 'email') as result
);
-- Expected: testuser@gmail.com

-- Test phone normalization
SELECT 
    result:normalized_dii::STRING as normalized,
    result:sha256_hash_base64::STRING as hash
FROM (
    SELECT UID2_CONVERTER_APP.APP_SCHEMA.hash_dii_for_uid2('+1-555-123-4567', 'phone') as result
);
-- Expected: +15551234567
```

### Test Batch Processing

```sql
-- Create sample data
CREATE OR REPLACE TEMPORARY TABLE sample_dii (dii STRING, dii_type STRING);
INSERT INTO sample_dii VALUES 
    ('user1@example.com', 'email'),
    ('user2@gmail.com', 'email'),
    ('+1-800-555-1234', 'phone');

-- Batch hash
SELECT t.* 
FROM sample_dii s, 
     TABLE(UID2_CONVERTER_APP.APP_SCHEMA.batch_hash_dii(s.dii, s.dii_type)) t;
```

### Test with UID2 API (Requires Credentials)

```sql
-- Replace with your actual UID2 credentials
SELECT UID2_CONVERTER_APP.APP_SCHEMA.convert_dii_to_uid2(
    'test@example.com',
    'email',
    'https://prod.uidapi.com',
    'YOUR_API_KEY',
    'YOUR_CLIENT_SECRET'
);
```

## Functions Reference

| Function | Description | Requirements |
|----------|-------------|--------------|
| `hash_dii_for_uid2(dii, type)` | Normalize and hash DII | Any warehouse |
| `convert_dii_to_uid2(dii, type, url, key, secret)` | Full UID2 conversion via API | Any warehouse + API creds |
| `batch_hash_dii(dii, type)` | Table function for batch hashing | Any warehouse |

## Cleanup

```sql
DROP APPLICATION IF EXISTS UID2_CONVERTER_APP;
DROP APPLICATION PACKAGE IF EXISTS UID2_CONVERTER_PKG;
DROP DATABASE IF EXISTS UID2_NATIVE_APP_DEV;
DROP WAREHOUSE IF EXISTS UID2_X86_WH;
```

## References

- [UID2 Documentation](https://unifiedid.com/docs)
- [UID2 Python SDK](https://github.com/IABTechLab/uid2-client-python)
- [Snowflake Native Apps](https://docs.snowflake.com/en/developer-guide/native-apps/native-apps-about)
- [Snowflake ARTIFACT_REPOSITORY](https://docs.snowflake.com/en/developer-guide/udf/python/udf-python-packages)

## License

Apache 2.0 - See LICENSE file
