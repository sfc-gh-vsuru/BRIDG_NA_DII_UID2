# UID2 Converter Native App

Convert Direct Identifying Information (DII) to Unified ID 2.0 (UID2) tokens directly within Snowflake.

## Features

- **Hash Function**: Normalize and hash emails/phone numbers locally (no API required)
- **Full UID2 Conversion**: Generate actual UID2 tokens via the UID2 API
- **Batch Processing**: Process multiple DIIs efficiently
- **Interactive Dashboard**: Streamlit-based UI for easy conversion

## Requirements

- Snowflake account with Native Apps enabled
- For full UID2 conversion: UID2 API credentials (API key + client secret)
- Snowpark-optimized warehouse with x86 architecture (for PyPI package)

## Quick Start

1. Install the app from the Snowflake Marketplace or deploy from source
2. Open the Streamlit dashboard
3. Enter DII values (emails or phone numbers)
4. Get normalized hashes or full UID2 tokens

## Architecture

This app uses Snowflake's `ARTIFACT_REPOSITORY` feature to directly access the `uid2-client` 
package from PyPI, eliminating the need for manual wheel bundling.

## Functions

| Function | Description | Requirements |
|----------|-------------|--------------|
| `hash_dii_for_uid2(dii, type)` | Normalize and hash DII | Standard warehouse |
| `convert_dii_to_uid2(dii, type, url, key, secret)` | Full UID2 conversion | x86 warehouse + API creds |
| `batch_hash_dii(dii, type)` | Table function for batch hashing | Standard warehouse |

## Version History

- **1.0.0** - Initial release with hash and conversion functions
