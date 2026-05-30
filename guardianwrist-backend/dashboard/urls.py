from django.urls import path
from . import views

app_name = 'dashboard'
urlpatterns = [
    path('', views.admin_dashboard, name='index'),
    path('users/', views.user_list, name='user_list'),
    path('users/<str:user_id>/', views.user_detail, name='user_detail'),
    path('health-records/', views.health_records_list, name='health_records'),
    path('users/<str:user_id>/insight/create/', views.create_insight, name='create_insight'),
    path('users/<str:user_id>/insight/<str:insight_id>/delete/', views.delete_insight, name='delete_insight'),
]