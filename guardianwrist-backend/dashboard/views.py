from django.shortcuts import render, redirect, get_object_or_404
from django.contrib.auth.decorators import login_required
from django.contrib.admin.views.decorators import staff_member_required
from django.core.paginator import Paginator
from django.contrib import messages
from guardianwrist_backend.firebase_config import db
from datetime import datetime
import uuid

@staff_member_required
def admin_dashboard(request):
    """Main dashboard with statistics."""
    users_ref = db.collection('users')
    users = list(users_ref.stream())
    total_users = len(users)
    premium_users = sum(1 for u in users if u.to_dict().get('premium', False))

    # Count health records (estimate – expensive, so we cap)
    health_count = 0
    for user in users[:10]:  # sample first 10 users
        health_ref = users_ref.document(user.id).collection('healthRecords')
        health_count += len(list(health_ref.limit(100).stream()))

    context = {
        'total_users': total_users,
        'premium_users': premium_users,
        'total_health_records': health_count,
        'recent_users': users[:5],
    }
    return render(request, 'dashboard/index.html', context)

@staff_member_required
def user_list(request):
    """List all users with search and pagination."""
    users_ref = db.collection('users')
    query = users_ref
    search = request.GET.get('search', '')
    if search:
        # Firestore doesn't support partial search easily, so we filter after fetch (small scale)
        docs = query.stream()
        users = []
        for doc in docs:
            data = doc.to_dict()
            if search.lower() in data.get('email', '').lower() or search.lower() in data.get('displayName', '').lower():
                data['id'] = doc.id
                users.append(data)
    else:
        docs = query.stream()
        users = []
        for doc in docs:
            data = doc.to_dict()
            data['id'] = doc.id
            users.append(data)
    paginator = Paginator(users, 20)
    page_number = request.GET.get('page')
    page_obj = paginator.get_page(page_number)
    return render(request, 'dashboard/user_list.html', {'page_obj': page_obj, 'search': search})

@staff_member_required
def user_detail(request, user_id):
    """Show user details, health records, insights, subscriptions."""
    user_doc = db.collection('users').document(user_id).get()
    if not user_doc.exists:
        messages.error(request, 'User not found')
        return redirect('user_list')
    user_data = user_doc.to_dict()
    user_data['id'] = user_doc.id

    # Health records
    health_ref = db.collection('users').document(user_id).collection('healthRecords')
    health_records = [{'id': doc.id, **doc.to_dict()} for doc in health_ref.order_by('recorded_at', direction='DESCENDING').limit(50).stream()]

    # Insights
    insights_ref = db.collection('users').document(user_id).collection('insights')
    insights = [{'id': doc.id, **doc.to_dict()} for doc in insights_ref.order_by('generated_at', direction='DESCENDING').limit(20).stream()]

    # Subscriptions
    subs_ref = db.collection('users').document(user_id).collection('subscriptions')
    subscriptions = [{'id': doc.id, **doc.to_dict()} for doc in subs_ref.stream()]

    context = {
        'user': user_data,
        'health_records': health_records,
        'insights': insights,
        'subscriptions': subscriptions,
    }
    return render(request, 'dashboard/user_detail.html', context)

@staff_member_required
def health_records_list(request):
    """List all health records across users (admin view)."""
    # Gather from all users – expensive, use pagination and limit
    users_ref = db.collection('users')
    users = users_ref.limit(20).stream()  # limit to 20 users for performance
    records = []
    for user in users:
        user_id = user.id
        health_ref = db.collection('users').document(user_id).collection('healthRecords')
        for doc in health_ref.order_by('recorded_at', direction='DESCENDING').limit(10).stream():
            data = doc.to_dict()
            data['id'] = doc.id
            data['user_id'] = user_id
            data['user_email'] = user.to_dict().get('email', 'Unknown')
            records.append(data)
    # Sort by recorded_at
    records.sort(key=lambda x: x.get('recorded_at', ''), reverse=True)
    paginator = Paginator(records, 30)
    page = request.GET.get('page')
    page_obj = paginator.get_page(page)
    return render(request, 'dashboard/health_records.html', {'page_obj': page_obj})

@staff_member_required
def create_insight(request, user_id):
    """Manually create an insight for a specific user."""
    if request.method == 'POST':
        data = {
            'title': request.POST.get('title'),
            'summary': request.POST.get('summary'),
            'detail': request.POST.get('detail'),
            'severity': request.POST.get('severity'),
            'is_premium': request.POST.get('is_premium') == 'on',
            'recommendation': request.POST.get('recommendation'),
            'generated_at': datetime.utcnow().isoformat(),
        }
        doc_ref = db.collection('users').document(user_id).collection('insights').document()
        doc_ref.set(data)
        messages.success(request, 'Insight created successfully.')
        return redirect('user_detail', user_id=user_id)
    return render(request, 'dashboard/insight_form.html', {'user_id': user_id})

@staff_member_required
def delete_insight(request, user_id, insight_id):
    """Delete an insight."""
    db.collection('users').document(user_id).collection('insights').document(insight_id).delete()
    messages.success(request, 'Insight deleted.')
    return redirect('user_detail', user_id=user_id)