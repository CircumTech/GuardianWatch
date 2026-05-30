from django.contrib import admin
from django.urls import path
from django.shortcuts import render
from django.utils.html import format_html
from .models import User, HealthRecord, Insight
from .firestore_admin import FirestoreModelAdmin
from guardianwrist_backend.firebase_config import db
from datetime import datetime, timedelta

# -------------------------------------------------------------------
# Custom admin dashboard (analytics)
# -------------------------------------------------------------------
def admin_dashboard(request):
    """Custom dashboard with Firestore analytics."""
    # Basic counts
    users_ref = db.collection('users')
    users = list(users_ref.stream())
    total_users = len(users)
    premium_users = sum(1 for u in users if u.to_dict().get('premium', False))

    # Active users in last 7 days (based on lastLoginAt)
    week_ago = (datetime.utcnow() - timedelta(days=7)).isoformat()
    active_users = 0
    for u in users:
        last_login = u.to_dict().get('lastLoginAt')
        if last_login and last_login > week_ago:
            active_users += 1

    # Health records count (sample)
    health_count = 0
    for u in users[:20]:  # limit to 20 users for performance
        health_ref = db.collection('users').document(u.id).collection('healthRecords')
        health_count += len(list(health_ref.limit(100).stream()))

    context = {
        'total_users': total_users,
        'premium_users': premium_users,
        'premium_percent': round(premium_users / total_users * 100, 1) if total_users else 0,
        'active_users': active_users,
        'total_health_records': health_count,
        'recent_users': users[:10],
    }
    return render(request, 'admin/dashboard.html', context)

# -------------------------------------------------------------------
# Custom ModelAdmins
# -------------------------------------------------------------------
@admin.register(User)
class UserAdmin(FirestoreModelAdmin):
    firestore_collection = 'users'
    list_display = ('id', 'email', 'displayName', 'premium', 'lastLoginAt')
    list_filter = ('premium',)
    search_fields = ('email', 'displayName', 'id')
    readonly_fields = ('id', 'createdAt', 'lastLoginAt')
    fieldsets = (
        (None, {'fields': ('id', 'email', 'displayName', 'photoURL')}),
        ('Subscription', {'fields': ('premium', 'premiumExpiry')}),
        ('Timestamps', {'fields': ('createdAt', 'lastLoginAt')}),
        ('Settings', {'fields': ('settings',)}),
    )

    def get_readonly_fields(self, request, obj=None):
        return self.readonly_fields

@admin.register(HealthRecord)
class HealthRecordAdmin(FirestoreModelAdmin):
    firestore_collection = 'healthRecords'   # but we override get_queryset to read from subcollection
    list_display = ('id', 'user_email', 'heart_rate', 'spo2', 'temperature', 'recorded_at')
    list_filter = ('recorded_at', 'heart_rate', 'spo2')
    search_fields = ('user__email', 'user__displayName', 'id')

    def get_queryset(self, request):
        # Collect health records from all users (expensive – limit to 1000)
        all_records = []
        users = db.collection('users').limit(100).stream()
        for user in users:
            health_records = db.collection(f'users/{user.id}/healthRecords').order_by('recorded_at', direction='DESCENDING').limit(50).stream()
            for doc in health_records:
                data = doc.to_dict()
                data['id'] = doc.id
                data['user_id'] = user.id
                data['user_email'] = user.to_dict().get('email', '')
                all_records.append(self.model(**data))
        return all_records

    def user_email(self, obj):
        return getattr(obj, 'user_email', '-')
    user_email.short_description = 'User Email'

@admin.register(Insight)
class InsightAdmin(FirestoreModelAdmin):
    firestore_collection = 'insights'   # similar override
    list_display = ('id', 'user_email', 'title', 'severity', 'is_premium', 'generated_at')
    list_filter = ('severity', 'is_premium')
    search_fields = ('title', 'user__email')

    def get_queryset(self, request):
        insights = []
        users = db.collection('users').limit(100).stream()
        for user in users:
            insight_docs = db.collection(f'users/{user.id}/insights').order_by('generated_at', direction='DESCENDING').limit(20).stream()
            for doc in insight_docs:
                data = doc.to_dict()
                data['id'] = doc.id
                data['user_id'] = user.id
                data['user_email'] = user.to_dict().get('email', '')
                insights.append(self.model(**data))
        return insights

    def user_email(self, obj):
        return getattr(obj, 'user_email', '-')
    user_email.short_description = 'User Email'

# -------------------------------------------------------------------
# Device model (optional – not in models.py, we create a proxy for admin)
# -------------------------------------------------------------------
class Device:
    """Dummy model for devices collection."""
    def __init__(self, **kwargs):
        for k, v in kwargs.items():
            setattr(self, k, v)

class DeviceAdmin(FirestoreModelAdmin):
    firestore_collection = 'devices'
    list_display = ('id', 'serialNumber', 'model', 'currentOwner', 'warrantyExpiry')
    search_fields = ('serialNumber', 'currentOwner')
    list_filter = ('model',)

# Register device admin only if collection exists (create lazily)
if db.collection('devices').limit(1).get():
    admin.site.register(type('Device', (), {'__module__': 'admin_panel'}), DeviceAdmin)

# -------------------------------------------------------------------
# Override admin site URLs to include custom dashboard
# -------------------------------------------------------------------
admin.site.site_header = 'GuardianWrist Admin'
admin.site.site_title = 'GuardianWrist Admin'
admin.site.index_title = 'Dashboard'

# Replace the default index view with our custom dashboard
admin.site.index_template = 'admin/dashboard.html'
original_get_urls = admin.site.get_urls

def get_urls(self):
    urls = original_get_urls(self)
    custom_urls = [
        path('dashboard/', admin_dashboard, name='admin_dashboard'),
    ]
    return custom_urls + urls

admin.site.get_urls = get_urls.__get__(admin.site)
# Customize admin site headers 
admin.site.site_header = 'GuardianWrist Admin Panel'
admin.site.site_title = 'GuardianWrist Admin'
admin.site.index_title = 'Welcome to GuardianWrist Admin Portal'