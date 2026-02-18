import streamlit as st
from snowflake.snowpark.context import get_active_session
import pandas as pd

st.set_page_config(
    page_title="UID2 Converter",
    layout="wide"
)

st.title("🔐 DII to UID2 Converter")
st.markdown("""
Convert Direct Identifying Information (DII) like emails and phone numbers to UID2 tokens.
This app demonstrates Snowflake Native App integration with the UID2 SDK.
""")

session = get_active_session()

tab1, tab2, tab3 = st.tabs(["Single Conversion", "Batch Conversion", "About"])

with tab1:
    st.header("Single DII Conversion")
    
    col1, col2 = st.columns(2)
    
    with col1:
        dii_type = st.selectbox("DII Type", ["email", "phone"], key="single_type")
        
        if dii_type == "email":
            dii_value = st.text_input("Email Address", placeholder="user@example.com", key="single_email")
        else:
            dii_value = st.text_input("Phone Number", placeholder="+1-555-123-4567", key="single_phone")
    
    with col2:
        st.subheader("UID2 API Credentials")
        st.info("Enter your UID2 API credentials to generate actual UID2 tokens. Leave empty to use hash-only mode.")
        
        base_url = st.text_input("API Base URL", value="https://prod.uidapi.com", key="api_url")
        api_key = st.text_input("API Key", type="password", key="api_key")
        client_secret = st.text_input("Client Secret", type="password", key="client_secret")
    
    if st.button("Convert to UID2", key="convert_single"):
        if not dii_value:
            st.error("Please enter a DII value")
        else:
            with st.spinner("Converting..."):
                hash_result = session.sql(f"""
                    SELECT APP_SCHEMA.hash_dii_for_uid2('{dii_value}', '{dii_type}') as result
                """).collect()[0]['RESULT']
                
                st.subheader("Hash Result (No API Required)")
                hash_df = pd.DataFrame([{
                    "Original DII": hash_result.get('original_dii', ''),
                    "Normalized DII": hash_result.get('normalized_dii', ''),
                    "SHA256 Hash (Base64)": hash_result.get('sha256_hash_base64', ''),
                    "Status": hash_result.get('status', '')
                }])
                st.dataframe(hash_df, use_container_width=True)
                
                if api_key and client_secret:
                    try:
                        uid2_result = session.sql(f"""
                            SELECT APP_SCHEMA.convert_dii_to_uid2(
                                '{dii_value}', 
                                '{dii_type}',
                                '{base_url}',
                                '{api_key}',
                                '{client_secret}'
                            ) as result
                        """).collect()[0]['RESULT']
                        
                        st.subheader("UID2 API Result")
                        if uid2_result.get('status') == 'success':
                            st.success("UID2 Generated Successfully!")
                            uid2_df = pd.DataFrame([{
                                "Raw UID2": uid2_result.get('raw_uid2', ''),
                                "Bucket ID": uid2_result.get('bucket_id', ''),
                                "Status": uid2_result.get('status', '')
                            }])
                            st.dataframe(uid2_df, use_container_width=True)
                        else:
                            st.error(f"Error: {uid2_result.get('error', 'Unknown error')}")
                    except Exception as e:
                        st.error(f"API Error: {str(e)}")

with tab2:
    st.header("Batch DII Conversion")
    st.markdown("Upload a CSV file with DII values for batch conversion.")
    
    uploaded_file = st.file_uploader("Upload CSV", type=['csv'], key="batch_upload")
    
    if uploaded_file:
        df = pd.read_csv(uploaded_file)
        st.write("Preview of uploaded data:")
        st.dataframe(df.head(), use_container_width=True)
        
        dii_column = st.selectbox("Select DII Column", df.columns.tolist(), key="dii_col")
        type_column = st.selectbox("Select Type Column (or None)", ["None"] + df.columns.tolist(), key="type_col")
        
        default_type = "email"
        if type_column == "None":
            default_type = st.selectbox("Default DII Type", ["email", "phone"], key="default_type")
        
        if st.button("Process Batch", key="process_batch"):
            with st.spinner("Processing batch..."):
                results = []
                for idx, row in df.iterrows():
                    dii_value = str(row[dii_column])
                    dii_type = row[type_column] if type_column != "None" else default_type
                    
                    try:
                        hash_result = session.sql(f"""
                            SELECT APP_SCHEMA.hash_dii_for_uid2('{dii_value}', '{dii_type}') as result
                        """).collect()[0]['RESULT']
                        
                        results.append({
                            "Original DII": dii_value,
                            "Type": dii_type,
                            "Normalized": hash_result.get('normalized_dii', ''),
                            "Hash (Base64)": hash_result.get('sha256_hash_base64', ''),
                            "Status": hash_result.get('status', '')
                        })
                    except Exception as e:
                        results.append({
                            "Original DII": dii_value,
                            "Type": dii_type,
                            "Normalized": "",
                            "Hash (Base64)": "",
                            "Status": f"Error: {str(e)}"
                        })
                
                results_df = pd.DataFrame(results)
                st.success(f"Processed {len(results)} records!")
                st.dataframe(results_df, use_container_width=True)
                
                csv = results_df.to_csv(index=False)
                st.download_button(
                    label="Download Results as CSV",
                    data=csv,
                    file_name="uid2_conversion_results.csv",
                    mime="text/csv"
                )

with tab3:
    st.header("About UID2")
    st.markdown("""
    ### What is UID2?
    
    Unified ID 2.0 (UID2) is an open-source identity solution that provides a privacy-conscious, 
    secure, and accurate identity standard for the digital advertising ecosystem.
    
    ### How it works:
    
    1. **Direct Identifying Information (DII)** - Email addresses or phone numbers
    2. **Normalization** - DIIs are normalized according to UID2 specifications
    3. **Hashing** - Normalized DIIs are hashed using SHA-256
    4. **UID2 Generation** - The UID2 API generates unique tokens from the hashes
    
    ### This Native App provides:
    
    - **Hash Function**: Normalize and hash DIIs locally (no API needed)
    - **Full Conversion**: Generate actual UID2 tokens via the UID2 API
    - **Batch Processing**: Process multiple DIIs at once
    
    ### Architecture:
    
    This app uses Snowflake's **ARTIFACT_REPOSITORY** feature to directly access the 
    `uid2-client` package from PyPI, running on x86 architecture for native code compatibility.
    
    ```
    ┌─────────────────────────────────────────────────────────┐
    │                   Streamlit Dashboard                    │
    ├─────────────────────────────────────────────────────────┤
    │  ┌─────────────────┐    ┌──────────────────────────┐   │
    │  │  hash_dii_for_  │    │  convert_dii_to_uid2     │   │
    │  │     uid2()      │    │  (PyPI: uid2-client)     │   │
    │  │  (Pure Python)  │    │  ARTIFACT_REPOSITORY     │   │
    │  └─────────────────┘    └──────────────────────────┘   │
    ├─────────────────────────────────────────────────────────┤
    │                  Snowflake Native App                    │
    │           (Versioned Schema + x86 Warehouse)            │
    └─────────────────────────────────────────────────────────┘
    ```
    
    ### References:
    - [UID2 Documentation](https://unifiedid.com/docs)
    - [UID2 Python SDK](https://github.com/IABTechLab/uid2-client-python)
    - [Snowflake Native Apps](https://docs.snowflake.com/en/developer-guide/native-apps/native-apps-about)
    """)
