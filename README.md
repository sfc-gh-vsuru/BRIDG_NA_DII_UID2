# UID2 Native App - DII to UID2 Converter

A Snowflake Native App that converts Direct Identifying Information (DII) — emails and phone numbers — to Unified ID 2.0 (UID2) tokens using [Trade Desk's official Python SDK](https://github.com/IABTechLab/uid2-client-python) (`uid2-client`).

## The Problem

The `uid2-client` Python library is not available in Snowflake's Anaconda channel. It depends on `bitarray` (a C extension), which cannot be bundled as a wheel or ZIP in Snowflake's read-only UDF filesystem. ARTIFACT_REPOSITORY works for standalone UDFs but fails inside Native Apps because the app's owner role lacks `SNOWFLAKE.PYPI_REPOSITORY_USER`.

## The Solution: Deferred UDF Creation Pattern

Instead of creating the PyPI-based UDF at install time (which fails), the app ships a **stored procedure** that creates the UDF at runtime — after the consumer grants the required database role.

```
Install Time                          Post-Install (Consumer)
─────────────                         ───────────────────────
App installs with:                    1. GRANT DATABASE ROLE
  - hash_dii_for_uid2() [works]         SNOWFLAKE.PYPI_REPOSITORY_USER
  - setup_uid2_sdk()    [procedure]      TO APPLICATION UID2_APP;
  - check_uid2_sdk_status()
                                      2. CALL setup_uid2_sdk();
                                         → Creates convert_dii_to_uid2()
                                           using ARTIFACT_REPOSITORY
                                           with uid2-client from PyPI
```

## Architecture

```
┌───────────────────────────────────────────────────────────────┐
│                    Snowflake Native App                        │
├───────────────────────────────────────────────────────────────┤
│                    Streamlit Dashboard                         │
│            (Single Conversion | Batch | About)                │
├────────────────────┬──────────────────────────────────────────┤
│  hash_dii_for_uid2 │  convert_dii_to_uid2                    │
│  (Pure Python)     │  (uid2-client from PyPI via              │
│  Any warehouse     │   ARTIFACT_REPOSITORY)                   │
│                    │  Requires: x86 warehouse + EAI           │
├────────────────────┴──────────────────────────────────────────┤
│  setup_uid2_sdk()          │  check_uid2_sdk_status()         │
│  Creates the PyPI UDF      │  Verifies if SDK is configured   │
│  after consumer grants     │                                  │
│  PYPI_REPOSITORY_USER      │                                  │
└────────────────────────────┴──────────────────────────────────┘
```

## Approach Comparison

| Approach | Status | Notes |
|----------|--------|-------|
| **Deferred ARTIFACT_REPOSITORY** | **Working** | Ship a procedure that creates the PyPI UDF post-install after consumer grants `PYPI_REPOSITORY_USER`. Uses Trade Desk's actual `uid2-client` SDK. |
| **ARTIFACT_REPOSITORY (direct)** | Works standalone only | Works for regular UDFs. Fails in Native App `setup.sql` because the app role lacks the PYPI database role at install time. |
| **Wheel/ZIP Bundling** | Failed | C extensions (`bitarray`) cannot load from the read-only UDF filesystem. `OSError: [Errno 30] Read-only file system`. |
| **Anaconda Re-implementation** | Fallback | Rewrite UID2 logic using `pycryptodome` + `requests` from Anaconda. Works but doesn't use the official SDK. |

## Key Technical Requirements

| Requirement | Detail |
|------------|--------|
| **Warehouse** | Snowpark-optimized with `RESOURCE_CONSTRAINT = 'MEMORY_16X_X86'` (uid2-client has native C extensions) |
| **PyPI Access** | `GRANT DATABASE ROLE SNOWFLAKE.PYPI_REPOSITORY_USER TO APPLICATION <app>` (requires ACCOUNTADMIN) |
| **Network Egress** | External Access Integration allowing HTTPS to UID2 API endpoints |
| **UID2 Credentials** | API key + client secret from [The Trade Desk](https://unifiedid.com/) |

## Project Structure

```
uid2_native_app/
├── manifest.yml                 # Native App manifest
├── readme.md                    # App readme (shown in Snowsight)
├── scripts/
│   └── setup.sql                # Setup script: hash UDF, deferred setup proc, Streamlit
├── app/
│   ├── streamlit/
│   │   ├── streamlit_app.py     # Interactive dashboard
│   │   └── environment.yml      # Streamlit dependencies
│   └── python/
│       └── uid2_converter.py    # Reference Python module
└── wheels/                      # Downloaded wheels (for reference, not used in final solution)
```

## Quick Start

### Prerequisites

1. Snowflake account with Native Apps enabled
2. A role with `CREATE DATABASE`, `CREATE APPLICATION PACKAGE`, `CREATE APPLICATION`, `CREATE WAREHOUSE`, `CREATE INTEGRATION` privileges
3. ACCOUNTADMIN access (for granting `PYPI_REPOSITORY_USER` to the app)
4. UID2 API credentials from The Trade Desk (for actual conversions)

### Step 1: Deploy the App

```sql
-- Create development database and stage
CREATE DATABASE IF NOT EXISTS UID2_APP_DEV;
CREATE SCHEMA IF NOT EXISTS UID2_APP_DEV.DEV;
CREATE STAGE IF NOT EXISTS UID2_APP_DEV.DEV.APP_STAGE
    DIRECTORY = (ENABLE = TRUE);

-- Upload files (from local filesystem)
PUT 'file:///path/to/uid2_native_app/manifest.yml'
    @UID2_APP_DEV.DEV.APP_STAGE/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT 'file:///path/to/uid2_native_app/readme.md'
    @UID2_APP_DEV.DEV.APP_STAGE/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT 'file:///path/to/uid2_native_app/scripts/setup.sql'
    @UID2_APP_DEV.DEV.APP_STAGE/scripts/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT 'file:///path/to/uid2_native_app/app/streamlit/streamlit_app.py'
    @UID2_APP_DEV.DEV.APP_STAGE/streamlit/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
PUT 'file:///path/to/uid2_native_app/app/streamlit/environment.yml'
    @UID2_APP_DEV.DEV.APP_STAGE/streamlit/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;

-- Create application package
CREATE APPLICATION PACKAGE UID2_APP_PKG;
CREATE SCHEMA IF NOT EXISTS UID2_APP_PKG.PKG_STAGE;
CREATE STAGE IF NOT EXISTS UID2_APP_PKG.PKG_STAGE.APP_STAGE
    DIRECTORY = (ENABLE = TRUE);

-- Copy files to package stage
COPY FILES INTO @UID2_APP_PKG.PKG_STAGE.APP_STAGE
    FROM @UID2_APP_DEV.DEV.APP_STAGE/manifest.yml;
COPY FILES INTO @UID2_APP_PKG.PKG_STAGE.APP_STAGE
    FROM @UID2_APP_DEV.DEV.APP_STAGE/readme.md;
COPY FILES INTO @UID2_APP_PKG.PKG_STAGE.APP_STAGE/scripts/
    FROM @UID2_APP_DEV.DEV.APP_STAGE/scripts/;
COPY FILES INTO @UID2_APP_PKG.PKG_STAGE.APP_STAGE/streamlit/
    FROM @UID2_APP_DEV.DEV.APP_STAGE/streamlit/;

-- Install the app (development mode)
CREATE APPLICATION UID2_APP
    FROM APPLICATION PACKAGE UID2_APP_PKG
    USING '@UID2_APP_PKG.PKG_STAGE.APP_STAGE';
```

### Step 2: Create the x86 Warehouse

The `uid2-client` package contains native C extensions (`bitarray`, `pycryptodome`) that require x86 architecture. Standard warehouses will fail with: `Cannot create or execute a Python function with 'X86' architecture annotation using a 'STANDARD_GEN_2' warehouse`.

```sql
CREATE WAREHOUSE IF NOT EXISTS UID2_WH WITH
    WAREHOUSE_SIZE = 'MEDIUM'
    WAREHOUSE_TYPE = 'SNOWPARK-OPTIMIZED'
    RESOURCE_CONSTRAINT = 'MEMORY_16X_X86';
```

### Step 3: Grant PyPI Repository Access (Requires ACCOUNTADMIN)

```sql
-- Run as ACCOUNTADMIN
GRANT DATABASE ROLE SNOWFLAKE.PYPI_REPOSITORY_USER TO APPLICATION UID2_APP;
```

This grants the app permission to pull packages from Snowflake's shared PyPI repository. Without this, the `ARTIFACT_REPOSITORY` clause in the UDF definition fails with `Object 'snowflake.snowpark.pypi_shared_repository' does not exist or not authorized`.

### Step 4: Create External Access Integration for UID2 API

The UDF makes outbound HTTPS calls to the UID2 API. Snowflake UDFs are sandboxed by default and cannot reach external endpoints without an External Access Integration.

```sql
-- Create network rule allowing egress to UID2 endpoints
CREATE OR REPLACE NETWORK RULE uid2_api_network_rule
    MODE = EGRESS
    TYPE = HOST_PORT
    VALUE_LIST = (
        'operator-integ.uidapi.com:443',
        'prod.uidapi.com:443',
        'operator.uidapi.com:443'
    );

-- Create the External Access Integration
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION uid2_api_access
    ALLOWED_NETWORK_RULES = (uid2_api_network_rule)
    ENABLED = TRUE;

-- Grant the integration to the app
GRANT USAGE ON INTEGRATION uid2_api_access TO APPLICATION UID2_APP;
```

### Step 5: Initialize the UID2 SDK

```sql
USE WAREHOUSE UID2_WH;
CALL UID2_APP.APP_SCHEMA.setup_uid2_sdk();
-- Returns: "UID2 SDK setup complete. convert_dii_to_uid2() is now available..."
```

This procedure dynamically creates the `convert_dii_to_uid2()` UDF using Trade Desk's `uid2-client` from PyPI via `ARTIFACT_REPOSITORY`.

### Step 6: Verify Setup

```sql
CALL UID2_APP.APP_SCHEMA.check_uid2_sdk_status();
-- Returns: "READY: convert_dii_to_uid2() is available. You can call it with an x86 warehouse."
```

## Testing

### Test Hash Function (No API Required, Any Warehouse)

```sql
SELECT 
    result:original_dii::STRING AS original,
    result:normalized_dii::STRING AS normalized,
    result:sha256_hash_base64::STRING AS hash
FROM (
    SELECT UID2_APP.APP_SCHEMA.hash_dii_for_uid2(
        'Test.User+promo@gmail.com', 'email'
    ) AS result
);
-- Expected normalized: testuser@gmail.com

SELECT 
    result:normalized_dii::STRING AS normalized,
    result:sha256_hash_base64::STRING AS hash
FROM (
    SELECT UID2_APP.APP_SCHEMA.hash_dii_for_uid2(
        '+1-555-123-4567', 'phone'
    ) AS result
);
-- Expected normalized: +15551234567
```

### Test UID2 Conversion (Requires Credentials + x86 Warehouse)

```sql
USE WAREHOUSE UID2_WH;

SELECT 
    r.value:status::STRING AS status,
    r.value:raw_uid2::STRING AS raw_uid2,
    r.value:bucket_id::STRING AS bucket_id,
    r.value:error::STRING AS error
FROM (
    SELECT UID2_APP.APP_SCHEMA.convert_dii_to_uid2(
        'user@example.com',
        'email',
        'https://prod.uidapi.com',    -- or 'https://operator-integ.uidapi.com' for testing
        'YOUR_API_KEY',
        'YOUR_CLIENT_SECRET_BASE64'
    ) AS value
) r;
```

**Expected results with test credentials:**
- `HTTP Error 401: Unauthorized` — confirms SDK loaded and network egress works, but credentials are invalid
- With valid credentials: `status = 'success'`, `raw_uid2` and `bucket_id` populated

### Test Without Credentials (Validate SDK Loading)

```sql
USE WAREHOUSE UID2_WH;

SELECT 
    r.value:status::STRING AS status,
    r.value:error::STRING AS error
FROM (
    SELECT UID2_APP.APP_SCHEMA.convert_dii_to_uid2(
        'test@example.com', 'email',
        'https://operator-integ.uidapi.com',
        'fake-key',
        'YOUR_CLIENT_SECRET_BASE64'
    ) AS value
) r;
-- Expected: status='error', error='HTTP Error 401: Unauthorized'
-- This confirms: uid2-client loaded, AES encryption worked, HTTP request reached the API
```

## Functions Reference

| Function | Description | Requirements |
|----------|-------------|--------------|
| `hash_dii_for_uid2(dii, type)` | Normalize and SHA-256 hash DII | Any warehouse |
| `convert_dii_to_uid2(dii, type, url, key, secret)` | Full UID2 conversion via Trade Desk SDK | x86 warehouse + EAI + API creds |
| `setup_uid2_sdk()` | Creates the PyPI-based UDF (call once after granting PYPI role) | x86 warehouse |
| `check_uid2_sdk_status()` | Returns READY or NOT CONFIGURED | Any warehouse |

## Updating the App

To update the app without losing the PYPI grant:

```sql
-- Upload new files to dev stage, copy to package stage, then:
ALTER APPLICATION UID2_APP UPGRADE USING '@UID2_APP_PKG.PKG_STAGE.APP_STAGE';

-- Re-run setup to recreate UDF with updated code
USE WAREHOUSE UID2_WH;
CALL UID2_APP.APP_SCHEMA.setup_uid2_sdk();
```

**Important:** Do NOT `DROP APPLICATION` and recreate — this loses the `PYPI_REPOSITORY_USER` grant which requires ACCOUNTADMIN to re-apply.

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `Object 'snowflake.snowpark.pypi_shared_repository' does not exist` | App doesn't have PYPI role | `GRANT DATABASE ROLE SNOWFLAKE.PYPI_REPOSITORY_USER TO APPLICATION UID2_APP` (ACCOUNTADMIN) |
| `Cannot create or execute... 'X86' architecture... 'STANDARD_GEN_2' warehouse` | Wrong warehouse type | Use a Snowpark-optimized warehouse with `RESOURCE_CONSTRAINT = 'MEMORY_16X_X86'` |
| `Device or resource busy` / connection refused | No external network access | Create EAI and grant to app (see Step 4) |
| `Incorrect AES key length` | Invalid client_secret format | Client secret must be a valid base64-encoded 32-byte key |
| `HTTP Error 401: Unauthorized` | Invalid API credentials | Use valid UID2 API key and client secret from The Trade Desk |
| `Grant not executed: Insufficient privileges` | Non-ACCOUNTADMIN role trying to grant PYPI | Must use ACCOUNTADMIN to grant database roles to applications |

## Snowflake Objects Created

| Object | Type | Purpose |
|--------|------|---------|
| `UID2_APP_DEV` | Database | Development staging area |
| `UID2_APP_PKG` | Application Package | Hosts the app files |
| `UID2_APP` | Application | Installed Native App |
| `UID2_WH` | Warehouse (Snowpark-optimized, x86) | Runs the uid2-client UDF |
| `uid2_api_network_rule` | Network Rule | Allows egress to UID2 API |
| `uid2_api_access` | External Access Integration | Enables UDF network access |

## Cleanup

```sql
DROP APPLICATION IF EXISTS UID2_APP;
DROP APPLICATION PACKAGE IF EXISTS UID2_APP_PKG;
DROP DATABASE IF EXISTS UID2_APP_DEV;
DROP WAREHOUSE IF EXISTS UID2_WH;
DROP INTEGRATION IF EXISTS uid2_api_access;
DROP NETWORK RULE IF EXISTS uid2_api_network_rule;
```

## Key Learnings

1. **ARTIFACT_REPOSITORY works in Native Apps** — but only via the deferred pattern where a procedure creates the UDF post-install after the consumer grants `SNOWFLAKE.PYPI_REPOSITORY_USER`.

2. **Use JavaScript for the setup procedure** — SQL's `EXECUTE IMMEDIATE` with nested dollar-quoting (`$py$` inside `$$`) causes parsing errors. A JavaScript procedure with template literals handles the quoting cleanly.

3. **The PYPI grant requires ACCOUNTADMIN** — the `SNOWFLAKE.PYPI_REPOSITORY_USER` database role is owned by the SNOWFLAKE application. Only roles with OWNERSHIP on SNOWFLAKE (effectively ACCOUNTADMIN) can grant it.

4. **`ALTER APPLICATION ... UPGRADE`** preserves grants — always prefer upgrading over drop/recreate to avoid losing the PYPI role grant.

5. **uid2-client API** uses plural methods: `IdentityMapInput.from_emails([list])`, `from_phones([list])`. The response `mapped_identities` is a dict keyed by raw DII, accessed via `.get_raw_uid()` and `.get_bucket_id()`.

## References

- [UID2 Documentation](https://unifiedid.com/docs)
- [UID2 Python SDK](https://github.com/IABTechLab/uid2-client-python)
- [Snowflake Native Apps](https://docs.snowflake.com/en/developer-guide/native-apps/native-apps-about)
- [Snowflake ARTIFACT_REPOSITORY](https://docs.snowflake.com/en/developer-guide/udf/python/udf-python-packages)
- [Snowflake External Access Integrations](https://docs.snowflake.com/en/developer-guide/external-network-access/external-network-access-overview)
