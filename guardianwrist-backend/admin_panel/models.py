from django.db import models
from django.utils import timezone
from guardianwrist_backend.firebase_config import db
import uuid

# -------------------------------------------------------------------
# Firestore Manager and QuerySet (working with admin)
# -------------------------------------------------------------------

class FirestoreQuerySet(models.QuerySet):
    """Queryset that reads from Firestore without hitting the database."""
    def __init__(self, *args, **kwargs):
        # Accept any extra kwargs (like 'query') to avoid cloning errors
        super().__init__(*args, **kwargs)
        self._firestore_cache = None

    def _fetch(self):
        if self._firestore_cache is None:
            collection_name = self.model.firestore_collection
            docs = db.collection(collection_name).stream()
            self._firestore_cache = []
            for doc in docs:
                data = doc.to_dict()
                data['id'] = doc.id
                self._firestore_cache.append(self.model(**data))
        return self._firestore_cache

    def _clone(self):
        clone = super()._clone()
        clone._firestore_cache = self._firestore_cache
        return clone

    def iterator(self):
        yield from self._fetch()

    def count(self):
        return len(self._fetch())

    def exists(self):
        return len(self._fetch()) > 0

    def get(self, *args, **kwargs):
        if 'id' in kwargs:
            doc = db.collection(self.model.firestore_collection).document(kwargs['id']).get()
            if doc.exists:
                data = doc.to_dict()
                data['id'] = doc.id
                return self.model(**data)
            raise self.model.DoesNotExist
        # Fallback: loop through cached items (inefficient but admin uses get(id) only)
        for obj in self._fetch():
            match = all(getattr(obj, k, None) == v for k, v in kwargs.items())
            if match:
                return obj
        raise self.model.DoesNotExist

    def filter(self, *args, **kwargs):
        # Simple equality filtering – enough for admin search
        results = self._fetch()
        filtered = []
        for obj in results:
            match = all(getattr(obj, k, None) == v for k, v in kwargs.items())
            if match:
                filtered.append(obj)
        clone = self._clone()
        clone._firestore_cache = filtered
        return clone

    def order_by(self, *field_names):
        # Admin uses order_by – we ignore ordering (Firestore already orders)
        return self


class FirestoreManager(models.Manager):
    def get_queryset(self):
        return FirestoreQuerySet(self.model, using=self._db)

    def create(self, **kwargs):
        # Create a new document in Firestore (used by admin's "add" action)
        if 'id' not in kwargs:
            kwargs['id'] = str(uuid.uuid4())
        data = {k: v for k, v in kwargs.items() if v is not None and k != 'id'}
        # Convert datetime to ISO string
        for key, value in data.items():
            if isinstance(value, (datetime, timezone.datetime)):
                data[key] = value.isoformat()
        doc_ref = db.collection(self.model.firestore_collection).document(kwargs['id'])
        doc_ref.set(data)
        return self.model(**kwargs)


# -------------------------------------------------------------------
# Models (unmanaged, Firestore-backed)
# -------------------------------------------------------------------

class User(models.Model):
    firestore_collection = 'users'

    id = models.CharField(max_length=255, primary_key=True)
    email = models.EmailField()
    displayName = models.CharField(max_length=255, blank=True)
    photoURL = models.URLField(blank=True, null=True)
    createdAt = models.DateTimeField(default=timezone.now)
    lastLoginAt = models.DateTimeField(blank=True, null=True)
    premium = models.BooleanField(default=False)
    premiumExpiry = models.DateTimeField(blank=True, null=True)
    settings = models.JSONField(default=dict, blank=True)

    objects = FirestoreManager()

    class Meta:
        managed = False
        app_label = 'admin_panel'
        verbose_name = 'User'
        verbose_name_plural = 'Users'

    def __str__(self):
        return self.email

    def save(self, *args, **kwargs):
        # Do NOT call super().save() – it would try to write to SQLite.
        # Instead, save to Firestore.
        data = {
            'email': self.email,
            'displayName': self.displayName,
            'photoURL': self.photoURL,
            'createdAt': self.createdAt.isoformat() if self.createdAt else None,
            'lastLoginAt': self.lastLoginAt.isoformat() if self.lastLoginAt else None,
            'premium': self.premium,
            'premiumExpiry': self.premiumExpiry.isoformat() if self.premiumExpiry else None,
            'settings': self.settings,
        }
        data = {k: v for k, v in data.items() if v is not None}
        db.collection(self.firestore_collection).document(self.id).set(data)

    def delete(self, *args, **kwargs):
        db.collection(self.firestore_collection).document(self.id).delete()


class HealthRecord(models.Model):
    firestore_collection = 'healthRecords'   # Actually under user subcollection

    id = models.CharField(max_length=255, primary_key=True)
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='health_records')
    heart_rate = models.PositiveSmallIntegerField()
    spo2 = models.PositiveSmallIntegerField()
    temperature = models.FloatField()
    recorded_at = models.DateTimeField()
    uploaded_at = models.DateTimeField(default=timezone.now)

    objects = FirestoreManager()

    class Meta:
        managed = False
        app_label = 'admin_panel'
        verbose_name = 'Health Record'
        verbose_name_plural = 'Health Records'

    def __str__(self):
        return f"{self.user.email} - {self.recorded_at}"

    def save(self, *args, **kwargs):
        if not self.id:
            self.id = str(uuid.uuid4())
        doc_ref = db.collection('users').document(self.user.id).collection('healthRecords').document(self.id)
        doc_ref.set({
            'heart_rate': self.heart_rate,
            'spo2': self.spo2,
            'temperature': self.temperature,
            'recorded_at': self.recorded_at.isoformat(),
            'uploaded_at': self.uploaded_at.isoformat(),
        })

    def delete(self, *args, **kwargs):
        db.collection('users').document(self.user.id).collection('healthRecords').document(self.id).delete()


class Insight(models.Model):
    SEVERITY_CHOICES = (
        ('normal', 'Normal'),
        ('caution', 'Caution'),
        ('warning', 'Warning'),
        ('critical', 'Critical'),
    )

    firestore_collection = 'insights'

    id = models.CharField(max_length=255, primary_key=True)
    user = models.ForeignKey(User, on_delete=models.CASCADE, related_name='insights')
    title = models.CharField(max_length=255)
    summary = models.TextField()
    detail = models.TextField()
    severity = models.CharField(max_length=20, choices=SEVERITY_CHOICES, default='normal')
    is_premium = models.BooleanField(default=False)
    recommendation = models.TextField(blank=True, null=True)
    generated_at = models.DateTimeField(default=timezone.now)

    objects = FirestoreManager()

    class Meta:
        managed = False
        app_label = 'admin_panel'
        verbose_name = 'Insight'
        verbose_name_plural = 'Insights'

    def __str__(self):
        return self.title

    def save(self, *args, **kwargs):
        if not self.id:
            self.id = str(uuid.uuid4())
        doc_ref = db.collection('users').document(self.user.id).collection('insights').document(self.id)
        doc_ref.set({
            'title': self.title,
            'summary': self.summary,
            'detail': self.detail,
            'severity': self.severity,
            'is_premium': self.is_premium,
            'recommendation': self.recommendation,
            'generated_at': self.generated_at.isoformat(),
        })

    def delete(self, *args, **kwargs):
        db.collection('users').document(self.user.id).collection('insights').document(self.id).delete()