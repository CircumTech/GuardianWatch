import logging
from datetime import datetime, timezone as dt_timezone
from typing import Tuple, Optional, Dict, Any

from rest_framework.decorators import api_view
from rest_framework.response import Response
from rest_framework import status
from firebase_admin import auth as firebase_auth
from django.utils import timezone
from django.core.validators import ValidationError
from google.cloud.firestore import Query

from guardianwrist_backend.firebase_config import db

logger = logging.getLogger(__name__)

# -------------------------------------------------------------------
# Constants for validation
# -------------------------------------------------------------------
MIN_HEART_RATE = 30
MAX_HEART_RATE = 220
MIN_SPO2 = 70
MAX_SPO2 = 100
MIN_TEMPERATURE = 30.0
MAX_TEMPERATURE = 45.0


# -------------------------------------------------------------------
# Helper functions
# -------------------------------------------------------------------
def verify_firebase_token(request) -> Tuple[Optional[Dict], Optional[Response]]:
    """Extract and verify Firebase ID token, return (decoded_token, None) or (None, error_response)."""
    auth_header = request.headers.get('Authorization')
    if not auth_header or not auth_header.startswith('Bearer '):
        return None, Response(
            {'error': 'Missing or invalid Authorization header. Use Bearer token.'},
            status=status.HTTP_401_UNAUTHORIZED
        )
    id_token = auth_header.split(' ')[1]
    try:
        decoded = firebase_auth.verify_id_token(id_token)
        return decoded, None
    except Exception as e:
        logger.warning(f"Token verification failed: {e}")
        return None, Response(
            {'error': 'Invalid or expired token'},
            status=status.HTTP_401_UNAUTHORIZED
        )


def get_or_create_user(uid: str, email: Optional[str] = None,
                       display_name: Optional[str] = None,
                       photo_url: Optional[str] = None) -> Dict:
    """Retrieve or create user document in Firestore. Returns user data dict."""
    user_ref = db.collection('users').document(uid)
    doc = user_ref.get()
    now_iso = timezone.now().isoformat()

    if doc.exists:
        user_data = doc.to_dict()
        # Update last login time
        user_ref.update({'lastLoginAt': now_iso})
        user_data['id'] = uid
        return user_data
    else:
        user_data = {
            'email': email,
            'displayName': display_name,
            'photoURL': photo_url,
            'createdAt': now_iso,
            'lastLoginAt': now_iso,
            'premium': False,
            'premiumExpiry': None,
            'settings': {}
        }
        user_ref.set(user_data)
        user_data['id'] = uid
        return user_data


def validate_health_record(record: Dict) -> Tuple[bool, Optional[str]]:
    """Validate a single health record. Returns (is_valid, error_message)."""
    heart_rate = record.get('heart_rate')
    spo2 = record.get('spo2')
    temperature = record.get('temperature')
    recorded_at = record.get('recorded_at')

    if heart_rate is not None:
        if not isinstance(heart_rate, int) or heart_rate < MIN_HEART_RATE or heart_rate > MAX_HEART_RATE:
            return False, f"Heart rate must be between {MIN_HEART_RATE} and {MAX_HEART_RATE}"
    if spo2 is not None:
        if not isinstance(spo2, int) or spo2 < MIN_SPO2 or spo2 > MAX_SPO2:
            return False, f"SpO₂ must be between {MIN_SPO2} and {MAX_SPO2}"
    if temperature is not None:
        if not isinstance(temperature, (int, float)) or temperature < MIN_TEMPERATURE or temperature > MAX_TEMPERATURE:
            return False, f"Temperature must be between {MIN_TEMPERATURE} and {MAX_TEMPERATURE}°C"
    if recorded_at:
        try:
            datetime.fromisoformat(recorded_at.replace('Z', '+00:00'))
        except Exception:
            return False, "recorded_at must be a valid ISO 8601 datetime"
    return True, None


# -------------------------------------------------------------------
# API Endpoints
# -------------------------------------------------------------------

@api_view(['POST'])
def upload_health_data(request):
    """
    Upload batch of health readings.
    Expected JSON:
    {
        "records": [
            {
                "heart_rate": 72,
                "spo2": 98,
                "temperature": 36.5,
                "recorded_at": "2025-03-20T08:30:00Z"
            }
        ]
    }
    """
    decoded, error_response = verify_firebase_token(request)
    if error_response:
        return error_response

    uid = decoded['uid']
    get_or_create_user(uid, decoded.get('email'), decoded.get('name'), decoded.get('picture'))

    records = request.data.get('records', [])
    if not records:
        return Response({'error': 'No records provided'}, status=status.HTTP_400_BAD_REQUEST)

    # Validate all records first
    validated_records = []
    for idx, rec in enumerate(records):
        is_valid, err_msg = validate_health_record(rec)
        if not is_valid:
            return Response(
                {'error': f'Invalid record at index {idx}: {err_msg}'},
                status=status.HTTP_400_BAD_REQUEST
            )
        # Prepare clean record data
        now_iso = timezone.now().isoformat()
        clean_rec = {
            'heart_rate': rec.get('heart_rate'),
            'spo2': rec.get('spo2'),
            'temperature': rec.get('temperature'),
            'recorded_at': rec.get('recorded_at', now_iso),
            'uploaded_at': now_iso
        }
        validated_records.append(clean_rec)

    # Batch write (max 500 per batch recommended)
    batch = db.batch()
    health_ref = db.collection('users').document(uid).collection('healthRecords')
    saved_ids = []
    for rec in validated_records:
        doc_ref = health_ref.document()
        batch.set(doc_ref, rec)
        saved_ids.append(doc_ref.id)

    try:
        batch.commit()
    except Exception as e:
        logger.error(f"Batch commit failed: {e}")
        return Response({'error': 'Database write failed'}, status=status.HTTP_500_INTERNAL_SERVER_ERROR)

    return Response({
        'success': True,
        'uploaded_count': len(saved_ids),
        'record_ids': saved_ids
    }, status=status.HTTP_201_CREATED)


@api_view(['GET'])
def get_history(request):
    """
    Fetch paginated health history.
    Query params: limit (default 20), start_after (document ID), from_date, to_date (ISO).
    """
    decoded, error_response = verify_firebase_token(request)
    if error_response:
        return error_response
    uid = decoded['uid']

    limit = min(int(request.query_params.get('limit', 20)), 100)  # cap at 100
    start_after = request.query_params.get('start_after')
    from_date = request.query_params.get('from_date')
    to_date = request.query_params.get('to_date')

    query: Query = db.collection('users').document(uid).collection('healthRecords') \
                    .order_by('recorded_at', direction=Query.DESCENDING)

    if from_date:
        query = query.where('recorded_at', '>=', from_date)
    if to_date:
        query = query.where('recorded_at', '<=', to_date)
    if start_after:
        start_doc = db.collection('users').document(uid).collection('healthRecords').document(start_after).get()
        if start_doc.exists:
            query = query.start_after(start_doc)

    docs = query.limit(limit).stream()
    records = [{**doc.to_dict(), 'id': doc.id} for doc in docs]

    return Response({
        'records': records,
        'count': len(records),
        'has_more': len(records) == limit
    }, status=status.HTTP_200_OK)


@api_view(['GET'])
def get_insights(request):
    """Get latest AI insights for the user."""
    decoded, error_response = verify_firebase_token(request)
    if error_response:
        return error_response
    uid = decoded['uid']

    insights_ref = db.collection('users').document(uid).collection('insights')
    docs = insights_ref.order_by('generated_at', direction=Query.DESCENDING).limit(50).stream()
    insights = [{**doc.to_dict(), 'id': doc.id} for doc in docs]
    return Response(insights, status=status.HTTP_200_OK)


@api_view(['PUT'])
def update_profile(request):
    """Update user profile fields: displayName, photoURL, settings."""
    decoded, error_response = verify_firebase_token(request)
    if error_response:
        return error_response
    uid = decoded['uid']

    allowed_fields = {'displayName', 'photoURL', 'settings'}
    update_data = {k: v for k, v in request.data.items() if k in allowed_fields and v is not None}

    if not update_data:
        return Response({'error': 'No valid fields to update'}, status=status.HTTP_400_BAD_REQUEST)

    user_ref = db.collection('users').document(uid)
    user_ref.update(update_data)
    return Response({'success': True, 'updated_fields': list(update_data.keys())}, status=status.HTTP_200_OK)


@api_view(['POST'])
def verify_receipt(request):
    """
    Verify in-app purchase receipt and activate premium.
    Expects: {'receipt': '...', 'product_id': '...', 'platform': 'ios/android'}
    """
    decoded, error_response = verify_firebase_token(request)
    if error_response:
        return error_response
    uid = decoded['uid']

    receipt = request.data.get('receipt')
    product_id = request.data.get('product_id')
    platform = request.data.get('platform')

    if not receipt or not product_id:
        return Response({'error': 'Missing receipt or product_id'}, status=status.HTTP_400_BAD_REQUEST)

    # ---------- TODO: Replace with actual receipt validation (Apple/Google) ----------
    # For production, implement validation using google-auth or apple's App Store Server API.
    # Example: verify with Google Play Developer API or Apple's /verifyReceipt endpoint.
    is_valid = True  # Placeholder – always valid for development
    # ---------------------------------------------------------------------------------

    if not is_valid:
        return Response({'error': 'Invalid receipt'}, status=status.HTTP_400_BAD_REQUEST)

    # Determine expiry
    now = timezone.now()
    if 'monthly' in product_id.lower():
        expiry = now + timezone.timedelta(days=30)
    elif 'annual' in product_id.lower():
        expiry = now + timezone.timedelta(days=365)
    else:
        expiry = now + timezone.timedelta(days=30)  # default monthly

    expiry_iso = expiry.isoformat()

    # Update user premium status
    user_ref = db.collection('users').document(uid)
    user_ref.update({
        'premium': True,
        'premiumExpiry': expiry_iso
    })

    # Store subscription record
    sub_ref = db.collection('users').document(uid).collection('subscriptions').document()
    sub_ref.set({
        'productId': product_id,
        'platform': platform,
        'purchaseDate': timezone.now().isoformat(),
        'expiryDate': expiry_iso,
        'verified': True,
        'receipt': receipt
    })

    return Response({
        'success': True,
        'premium': True,
        'expiry': expiry_iso
    }, status=status.HTTP_200_OK)


@api_view(['GET'])
def subscription_status(request):
    """Get current user's premium status."""
    decoded, error_response = verify_firebase_token(request)
    if error_response:
        return error_response
    uid = decoded['uid']

    user_doc = db.collection('users').document(uid).get()
    if not user_doc.exists:
        return Response({'premium': False, 'active': False}, status=status.HTTP_200_OK)

    user_data = user_doc.to_dict()
    premium = user_data.get('premium', False)
    expiry = user_data.get('premiumExpiry')
    active = premium and (expiry is None or datetime.fromisoformat(expiry.replace('Z', '+00:00')) > datetime.now(dt_timezone.utc))

    return Response({
        'premium': premium,
        'expiry': expiry,
        'active': active
    }, status=status.HTTP_200_OK)