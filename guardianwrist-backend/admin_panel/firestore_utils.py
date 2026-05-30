from guardianwrist_backend.firebase_config import db
from datetime import datetime

def get_user(uid):
    doc = db.collection('users').document(uid).get()
    return doc.to_dict() if doc.exists else None

def create_user(uid, email, display_name=None):
    user_ref = db.collection('users').document(uid)
    user_ref.set({
        'email': email,
        'displayName': display_name,
        'createdAt': datetime.utcnow().isoformat(),
        'premium': False,
        'settings': {}
    })
    return get_user(uid)

def add_health_record(uid, data):
    rec_ref = db.collection('users').document(uid).collection('healthRecords').document()
    rec_ref.set({
        'heart_rate': data.get('heart_rate'),
        'spo2': data.get('spo2'),
        'temperature': data.get('temperature'),
        'recorded_at': data.get('recorded_at', datetime.utcnow().isoformat()),
        'uploaded_at': datetime.utcnow().isoformat(),
    })
    return rec_ref.id

def get_health_records(uid, limit=20, start_after=None):
    query = db.collection('users').document(uid).collection('healthRecords')\
                .order_by('recorded_at', direction='DESCENDING').limit(limit)
    if start_after:
        start_doc = db.collection('users').document(uid).collection('healthRecords').document(start_after).get()
        if start_doc.exists:
            query = query.start_after(start_doc)
    return [{**doc.to_dict(), 'id': doc.id} for doc in query.stream()]

def get_insights(uid):
    return [{**doc.to_dict(), 'id': doc.id} for doc in db.collection('users').document(uid)
            .collection('insights').order_by('generated_at', direction='DESCENDING').limit(50).stream()]

def update_user_profile(uid, data):
    db.collection('users').document(uid).update(data)

def set_premium(uid, premium, expiry_iso=None):
    update = {'premium': premium}
    if expiry_iso:
        update['premiumExpiry'] = expiry_iso
    db.collection('users').document(uid).update(update)