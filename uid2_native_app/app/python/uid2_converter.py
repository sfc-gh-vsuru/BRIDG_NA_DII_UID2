"""
UID2 Conversion Module
Provides functions to convert Direct Identifying Information (DII) to UID2 tokens.
Supports both email and phone number inputs.
"""

import hashlib
import base64
from typing import Optional
from uid2_client import IdentityMapClient, IdentityMapInput


def normalize_email(email: str) -> str:
    """Normalize email according to UID2 specification."""
    email = email.lower().strip()
    local, domain = email.rsplit('@', 1)
    if domain in ('gmail.com', 'googlemail.com'):
        local = local.replace('.', '').split('+')[0]
    return f"{local}@{domain}"


def normalize_phone(phone: str) -> str:
    """Normalize phone number to E.164 format."""
    digits = ''.join(c for c in phone if c.isdigit() or c == '+')
    if not digits.startswith('+'):
        digits = '+1' + digits
    return digits


def hash_dii(dii: str, is_phone: bool = False) -> str:
    """Hash DII using SHA-256 and base64 encode."""
    if is_phone:
        normalized = normalize_phone(dii)
    else:
        normalized = normalize_email(dii)
    hashed = hashlib.sha256(normalized.encode('utf-8')).digest()
    return base64.b64encode(hashed).decode('utf-8')


def generate_raw_uid2_from_dii(
    dii: str,
    dii_type: str,
    base_url: str,
    api_key: str,
    client_secret: str
) -> dict:
    """
    Convert DII (email or phone) to UID2 using the UID2 SDK.
    
    Args:
        dii: The direct identifying information (email or phone)
        dii_type: Either 'email' or 'phone'
        base_url: UID2 API base URL
        api_key: UID2 API key
        client_secret: UID2 client secret
    
    Returns:
        dict with 'raw_uid2', 'bucket_id', or 'error'
    """
    try:
        client = IdentityMapClient(base_url, api_key, client_secret)
        
        if dii_type.lower() == 'email':
            identity = IdentityMapInput.from_email(dii)
        elif dii_type.lower() == 'phone':
            identity = IdentityMapInput.from_phone(dii)
        else:
            return {'error': f'Invalid dii_type: {dii_type}. Must be email or phone.'}
        
        response = client.generate_identity_map([identity])
        
        if response.mapped_identities:
            mapped = response.mapped_identities[0]
            return {
                'raw_uid2': mapped.raw_uid,
                'bucket_id': mapped.bucket_id,
                'advertising_id': str(mapped.advertising_id) if hasattr(mapped, 'advertising_id') else None
            }
        elif response.unmapped_identities:
            unmapped = response.unmapped_identities[0]
            return {'error': f'Identity not mapped: {unmapped.reason}'}
        else:
            return {'error': 'No response from UID2 API'}
            
    except Exception as e:
        return {'error': str(e)}


def batch_convert_dii_to_uid2(
    dii_list: list,
    dii_types: list,
    base_url: str,
    api_key: str,
    client_secret: str
) -> list:
    """
    Batch convert multiple DIIs to UID2.
    
    Args:
        dii_list: List of DIIs
        dii_types: List of types corresponding to each DII
        base_url: UID2 API base URL
        api_key: UID2 API key
        client_secret: UID2 client secret
    
    Returns:
        List of results
    """
    results = []
    for dii, dii_type in zip(dii_list, dii_types):
        result = generate_raw_uid2_from_dii(dii, dii_type, base_url, api_key, client_secret)
        result['input_dii'] = dii
        result['dii_type'] = dii_type
        results.append(result)
    return results
