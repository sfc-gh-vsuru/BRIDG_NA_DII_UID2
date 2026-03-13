# UID2 Native App — Step-by-Step Guide (Snowsight)

This guide walks through deploying and testing the UID2 Native App using the **Deferred UDF Creation** workaround. Every SQL block below is copy-pasteable into a Snowsight worksheet.

> **What is the Deferred Pattern?**
> The `uid2-client` PyPI package cannot be loaded at app install time because the app role lacks `SNOWFLAKE.PYPI_REPOSITORY_USER`. Instead, the app ships a stored procedure (`setup_uid2_sdk()`) that creates the PyPI-based UDF *after* the consumer grants the required database role.

---

## Prerequisites

- Snowflake account with Native Apps enabled
- A role with `CREATE DATABASE`, `CREATE APPLICATION PACKAGE`, `CREATE APPLICATION`, `CREATE INTEGRATION` privileges
- ACCOUNTADMIN access (needed once to grant `PYPI_REPOSITORY_USER`)
- Local project files at a known path (referenced as `/path/to/uid2_native_app/` below — replace with your actual path)

---

## Step 1 — Create the Development Database and Stage

Open a Snowsight worksheet and run:

```sql
CREATE DATABASE IF NOT EXISTS UID2_APP_DEV;
CREATE SCHEMA IF NOT EXISTS UID2_APP_DEV.DEV;
CREATE STAGE IF NOT EXISTS UID2_APP_DEV.DEV.APP_STAGE
    DIRECTORY = (ENABLE = TRUE);
```

---

## Step 2 — Upload App Files to the Dev Stage

Replace `/path/to/uid2_native_app` with your actual local path.

```sql
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
```

Verify the upload:

```sql
LIST @UID2_APP_DEV.DEV.APP_STAGE;
```

You should see: `manifest.yml`, `readme.md`, `scripts/setup.sql`, `streamlit/streamlit_app.py`, `streamlit/environment.yml`.

---

## Step 3 — Create the Application Package

```sql
CREATE APPLICATION PACKAGE IF NOT EXISTS UID2_APP_PKG;
CREATE SCHEMA IF NOT EXISTS UID2_APP_PKG.PKG_STAGE;
CREATE STAGE IF NOT EXISTS UID2_APP_PKG.PKG_STAGE.APP_STAGE
    DIRECTORY = (ENABLE = TRUE);
```

---

## Step 4 — Copy Files to the Package Stage

```sql
COPY FILES INTO @UID2_APP_PKG.PKG_STAGE.APP_STAGE
    FROM @UID2_APP_DEV.DEV.APP_STAGE/manifest.yml;

COPY FILES INTO @UID2_APP_PKG.PKG_STAGE.APP_STAGE
    FROM @UID2_APP_DEV.DEV.APP_STAGE/readme.md;

COPY FILES INTO @UID2_APP_PKG.PKG_STAGE.APP_STAGE/scripts/
    FROM @UID2_APP_DEV.DEV.APP_STAGE/scripts/;

COPY FILES INTO @UID2_APP_PKG.PKG_STAGE.APP_STAGE/streamlit/
    FROM @UID2_APP_DEV.DEV.APP_STAGE/streamlit/;
```

Verify:

```sql
LIST @UID2_APP_PKG.PKG_STAGE.APP_STAGE;
```

---

## Step 5 — Install the Native App

```sql
CREATE APPLICATION UID2_APP
    FROM APPLICATION PACKAGE UID2_APP_PKG
    USING '@UID2_APP_PKG.PKG_STAGE.APP_STAGE';
```

At this point the app is installed with:
- `hash_dii_for_uid2()` — works immediately (pure Python)
- `setup_uid2_sdk()` — procedure to create the PyPI UDF later
- `check_uid2_sdk_status()` — tells you if the SDK UDF exists yet

The `convert_dii_to_uid2()` UDF does **not** exist yet.

---

## Step 6 — Create a Snowpark-Optimized (x86) Warehouse

The `uid2-client` package has native C extensions (`bitarray`, `pycryptodome`) that require x86 architecture. A standard warehouse will fail.

```sql
CREATE WAREHOUSE IF NOT EXISTS UID2_WH WITH
    WAREHOUSE_SIZE = 'MEDIUM'
    WAREHOUSE_TYPE = 'SNOWPARK-OPTIMIZED'
    RESOURCE_CONSTRAINT = 'MEMORY_16X_X86';
```

---

## Step 7 — Grant PyPI Repository Access (ACCOUNTADMIN Required)

Switch to ACCOUNTADMIN in Snowsight (top-left role selector), then run:

```sql
GRANT DATABASE ROLE SNOWFLAKE.PYPI_REPOSITORY_USER TO APPLICATION UID2_APP;
```

> **Why ACCOUNTADMIN?** The SNOWFLAKE database is a system application. Only ACCOUNTADMIN can grant its database roles to other applications.

Switch back to your working role after this step.

---

## Step 8 — Create Network Rule and External Access Integration

The UDF makes outbound HTTPS calls to the UID2 API. Without an External Access Integration, calls fail with `Device or resource busy`.

```sql
CREATE OR REPLACE NETWORK RULE UID2_APP_DEV.DEV.uid2_api_network_rule
    MODE = EGRESS
    TYPE = HOST_PORT
    VALUE_LIST = (
        'operator-integ.uidapi.com:443',
        'prod.uidapi.com:443',
        'operator.uidapi.com:443'
    );

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION uid2_api_access
    ALLOWED_NETWORK_RULES = (UID2_APP_DEV.DEV.uid2_api_network_rule)
    ENABLED = TRUE;

GRANT USAGE ON INTEGRATION uid2_api_access TO APPLICATION UID2_APP;
```

---

## Step 9 — Run the Deferred Setup Procedure

This is the key step. The procedure dynamically creates `convert_dii_to_uid2()` using Trade Desk's `uid2-client` from PyPI via `ARTIFACT_REPOSITORY`.

```sql
USE WAREHOUSE UID2_WH;
CALL UID2_APP.APP_SCHEMA.setup_uid2_sdk();
```

**Expected output:**
```
UID2 SDK setup complete. convert_dii_to_uid2() is now available using Trade Desk uid2-client from PyPI.
```

---

## Step 10 — Verify Setup

```sql
CALL UID2_APP.APP_SCHEMA.check_uid2_sdk_status();
```

**Expected output:**
```
READY: convert_dii_to_uid2() is available. You can call it with an x86 warehouse.
```

---

## Testing

### Test A — Hash Function (No API, Any Warehouse)

This works on any warehouse and requires no credentials or network access.

**Email normalization and hashing:**

```sql
SELECT
    result:original_dii::STRING   AS original,
    result:normalized_dii::STRING AS normalized,
    result:sha256_hash_base64::STRING AS hash_b64,
    result:status::STRING         AS status
FROM (
    SELECT UID2_APP.APP_SCHEMA.hash_dii_for_uid2(
        'Test.User+promo@gmail.com', 'email'
    ) AS result
);
```

**Expected:** normalized = `testuser@gmail.com`, status = `success`

**Phone normalization and hashing:**

```sql
SELECT
    result:normalized_dii::STRING AS normalized,
    result:sha256_hash_base64::STRING AS hash_b64,
    result:status::STRING         AS status
FROM (
    SELECT UID2_APP.APP_SCHEMA.hash_dii_for_uid2(
        '+1-555-123-4567', 'phone'
    ) AS result
);
```

**Expected:** normalized = `+15551234567`, status = `success`

---

### Test B — UID2 SDK Validation (Fake Credentials, x86 Warehouse)

This proves the full pipeline works: uid2-client loads from PyPI, AES encryption initializes, and the HTTP request reaches the UID2 API. With fake credentials you will get a 401 — that is the expected success signal.

```sql
USE WAREHOUSE UID2_WH;

SELECT
    r.value:status::STRING  AS status,
    r.value:error::STRING   AS error
FROM (
    SELECT UID2_APP.APP_SCHEMA.convert_dii_to_uid2(
        'test@example.com',
        'email',
        'https://operator-integ.uidapi.com',
        'fake-api-key',
        'ioG3wKxAokmp+rERx6A4kM/13qhyolUXIu14WN+c/sE='
    ) AS value
) r;
```

**Expected output:**

| STATUS | ERROR |
|--------|-------|
| error  | HTTP Error 401: Unauthorized |

This confirms:
1. `uid2-client` loaded successfully from PyPI
2. `bitarray` and `pycryptodome` C extensions work on x86
3. AES encryption initialized (client_secret was decoded and used)
4. Outbound HTTPS reached the UID2 API (External Access Integration works)
5. Only the credentials are invalid — everything else is functional

---

### Test C — Live UID2 Conversion (Real Credentials, x86 Warehouse)

Replace with your actual UID2 API credentials from The Trade Desk:

```sql
USE WAREHOUSE UID2_WH;

SELECT
    r.value:status::STRING     AS status,
    r.value:raw_uid2::STRING   AS raw_uid2,
    r.value:bucket_id::STRING  AS bucket_id,
    r.value:error::STRING      AS error
FROM (
    SELECT UID2_APP.APP_SCHEMA.convert_dii_to_uid2(
        'user@example.com',
        'email',
        'https://prod.uidapi.com',
        'YOUR_API_KEY',
        'YOUR_CLIENT_SECRET_BASE64'
    ) AS value
) r;
```

**Expected:** status = `success`, raw_uid2 and bucket_id populated.

---

## Updating the App (Without Losing Grants)

If you modify `setup.sql` or other files, re-upload and upgrade — do NOT drop the app.

```sql
-- Re-upload changed files to dev stage
PUT 'file:///path/to/uid2_native_app/scripts/setup.sql'
    @UID2_APP_DEV.DEV.APP_STAGE/scripts/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;

-- Copy to package stage
COPY FILES INTO @UID2_APP_PKG.PKG_STAGE.APP_STAGE/scripts/
    FROM @UID2_APP_DEV.DEV.APP_STAGE/scripts/;

-- Upgrade (preserves PYPI_REPOSITORY_USER grant)
ALTER APPLICATION UID2_APP UPGRADE USING '@UID2_APP_PKG.PKG_STAGE.APP_STAGE';

-- Re-run setup to recreate the UDF with updated code
USE WAREHOUSE UID2_WH;
CALL UID2_APP.APP_SCHEMA.setup_uid2_sdk();
```

> **Warning:** `DROP APPLICATION` and recreating it will lose the `PYPI_REPOSITORY_USER` grant, requiring ACCOUNTADMIN to re-grant.

---

## Cleanup

To remove all objects created by this guide:

```sql
DROP APPLICATION IF EXISTS UID2_APP;
DROP APPLICATION PACKAGE IF EXISTS UID2_APP_PKG;
DROP DATABASE IF EXISTS UID2_APP_DEV;
DROP WAREHOUSE IF EXISTS UID2_WH;
DROP INTEGRATION IF EXISTS uid2_api_access;
-- Network rule lives in UID2_APP_DEV which was already dropped
```

---

## Quick Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Object 'snowflake.snowpark.pypi_shared_repository' does not exist` | Missing PYPI grant | Run Step 7 as ACCOUNTADMIN |
| `Cannot create or execute... 'X86'... 'STANDARD_GEN_2' warehouse` | Wrong warehouse type | Use `UID2_WH` (Snowpark-optimized x86) — Step 6 |
| `Device or resource busy` | No External Access Integration | Run Step 8 |
| `HTTP Error 401: Unauthorized` | Invalid API credentials | Expected with fake keys; use real UID2 credentials for production |
| `Incorrect AES key length` | Bad client_secret | Must be valid base64-encoded 32-byte key |
| `Insufficient privileges` on PYPI grant | Not ACCOUNTADMIN | Switch to ACCOUNTADMIN for Step 7 |
