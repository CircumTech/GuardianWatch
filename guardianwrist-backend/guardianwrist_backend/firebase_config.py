import firebase_admin
from firebase_admin import credentials, firestore
from django.conf import settings
import os

def initialize_firebase():
    """Initialize the Firebase Admin SDK"""
    if not firebase_admin._apps:
        cred_path = os.path.join(settings.BASE_DIR, 'guardianwrist_backend', 'firebase-adminsdk.json')
        cred = credentials.Certificate(cred_path)
        default_app = firebase_admin.initialize_app(cred)
        return default_app
    return firebase_admin.get_app()

# Initialize on module load
initialize_firebase()

# Get Firestore client
db = firestore.client()
