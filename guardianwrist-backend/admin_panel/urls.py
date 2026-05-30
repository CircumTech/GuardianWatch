from django.urls import path
from . import views

urlpatterns = [
    path('upload/', views.upload_health_data, name='upload_health'),
    path('history/', views.get_history, name='get_history'),
    path('insights/', views.get_insights, name='get_insights'),
    path('profile/', views.update_profile, name='update_profile'),
    path('verify_receipt/', views.verify_receipt, name='verify_receipt'),
    path('subscription/', views.subscription_status, name='subscription_status'),
]