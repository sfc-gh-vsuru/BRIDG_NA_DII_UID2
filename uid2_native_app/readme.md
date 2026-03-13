# UID2 Converter Native App

Convert Direct Identifying Information (DII) — emails and phone numbers — to Unified ID 2.0 (UID2) tokens directly within Snowflake using Trade Desk's official `uid2-client` Python SDK.

## Features

- **Hash Function**: Normalize and SHA-256 hash emails/phone numbers locally (no API required, any warehouse)
- **Full UID2 Conversion**: Generate actual UID2 tokens via Trade Desk's `uid2-client` SDK from PyPI
- **Interactive Dashboard**: Streamlit-based UI for single and batch conversion

## Post-Install Setup (Required)

The `uid2-client` package is loaded from PyPI via `ARTIFACT_REPOSITORY`. Because the app role lacks `SNOWFLAKE.PYPI_REPOSITORY_USER` at install time, the UID2 conversion UDF is created **after** install via a setup procedure.

**Step 1 — Grant PyPI access (requires ACCOUNTADMIN):**
```sql
GRANT DATABASE ROLE SNOWFLAKE.PYPI_REPOSITORY_USER TO APPLICATION <app_name>;
```

**Step 2 — Create External Access Integration for UID2 API:**
```sql
CREATE OR REPLACE NETWORK RULE <db>.<schema>.uid2_api_network_rule
    MODE = EGRESS TYPE = HOST_PORT
    VALUE_LIST = ('operator-integ.uidapi.com:443','prod.uidapi.com:443','operator.uidapi.com:443');

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION uid2_api_access
    ALLOWED_NETWORK_RULES = (<db>.<schema>.uid2_api_network_rule) ENABLED = TRUE;

GRANT USAGE ON INTEGRATION uid2_api_access TO APPLICATION <app_name>;
```

**Step 3 — Run setup procedure (use a Snowpark-optimized x86 warehouse):**
```sql
USE WAREHOUSE <x86_warehouse>;
CALL <app_name>.APP_SCHEMA.setup_uid2_sdk();
```

**Step 4 — Verify:**
```sql
CALL <app_name>.APP_SCHEMA.check_uid2_sdk_status();
-- Expected: "READY: convert_dii_to_uid2() is available."
```

## Requirements

- Snowflake account with Native Apps enabled
- ACCOUNTADMIN access (one-time, for granting `PYPI_REPOSITORY_USER`)
- Snowpark-optimized warehouse with `RESOURCE_CONSTRAINT = 'MEMORY_16X_X86'`
- External Access Integration allowing HTTPS to UID2 API endpoints
- UID2 API credentials from The Trade Desk (for actual conversions)

## Functions

| Function | Description | Requirements |
|----------|-------------|--------------|
| `hash_dii_for_uid2(dii, type)` | Normalize and SHA-256 hash DII | Any warehouse |
| `convert_dii_to_uid2(dii, type, url, key, secret)` | Full UID2 conversion via Trade Desk SDK | x86 warehouse + EAI + API creds |
| `setup_uid2_sdk()` | Creates the PyPI-based UDF (call once after granting PYPI role) | x86 warehouse |
| `check_uid2_sdk_status()` | Returns READY or NOT CONFIGURED | Any warehouse |

## Version History

- **1.0.0** - Initial release with deferred UDF creation pattern for uid2-client from PyPI
