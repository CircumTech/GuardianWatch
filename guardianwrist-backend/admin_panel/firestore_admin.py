from django.contrib.admin import ModelAdmin
from django import forms
from guardianwrist_backend.firebase_config import db
from typing import List, Dict, Any
import logging

logger = logging.getLogger(__name__)

class FirestoreModelAdmin(ModelAdmin):
    """
    Base admin class that reads/writes from/to Firestore instead of a database.
    Subclasses must set `firestore_collection` and define a corresponding model.
    """
    firestore_collection: str = None
    list_display = None
    list_filter = []
    search_fields = []
    list_per_page = 20

    def get_queryset(self, request):
        """Return a list of model instances populated from Firestore."""
        if not self.firestore_collection:
            return []
        docs = db.collection(self.firestore_collection).stream()
        items = []
        for doc in docs:
            data = doc.to_dict()
            data['id'] = doc.id
            # Convert Firestore timestamps to datetime if needed
            for key, value in data.items():
                if hasattr(value, 'isoformat'):
                    data[key] = value
            obj = self.model(**data)
            items.append(obj)
        return items

    def get_list_display(self, request):
        if self.list_display:
            return self.list_display
        # Auto-detect from first document
        docs = db.collection(self.firestore_collection).limit(1).stream()
        for doc in docs:
            return list(doc.to_dict().keys())
        return ['id']

    def has_add_permission(self, request):
        return True

    def has_change_permission(self, request, obj=None):
        return True

    def has_delete_permission(self, request, obj=None):
        return True

    def save_model(self, request, obj, form, change):
        """Save to Firestore on admin save."""
        data = form.cleaned_data
        doc_id = data.pop('id', None) or getattr(obj, 'id', None)
        # Remove None values and convert datetime to ISO
        cleaned = {}
        for k, v in data.items():
            if v is not None:
                if hasattr(v, 'isoformat'):
                    v = v.isoformat()
                cleaned[k] = v
        if doc_id:
            db.collection(self.firestore_collection).document(doc_id).set(cleaned)
        else:
            doc_ref = db.collection(self.firestore_collection).document()
            doc_ref.set(cleaned)
            obj.id = doc_ref.id

    def delete_model(self, request, obj):
        doc_id = getattr(obj, 'id', None)
        if doc_id:
            db.collection(self.firestore_collection).document(doc_id).delete()