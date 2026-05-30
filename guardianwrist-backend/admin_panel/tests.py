import json
from datetime import datetime, timedelta
from unittest.mock import patch, MagicMock

from django.test import TestCase, Client
from django.contrib.auth.models import User as DjangoUser
from django.urls import reverse

# -------------------------------------------------------------------
# API Tests (mocking Firestore and Firebase Auth)
# -------------------------------------------------------------------

class APITests(TestCase):
    def setUp(self):
        self.client = Client()
        self.user_uid = "test_uid_123"
        self.valid_token = "valid_firebase_token"

    @patch('admin_panel.views.firebase_auth.verify_id_token')
    def _mock_auth(self, mock_verify, email="test@example.com", name="Test User"):
        mock_verify.return_value = {
            'uid': self.user_uid,
            'email': email,
            'name': name,
            'picture': None
        }

    @patch('admin_panel.views.db')
    @patch('admin_panel.views.firebase_auth.verify_id_token')
    def test_upload_health_data_success(self, mock_verify, mock_db):
        self._mock_auth(mock_verify)
        mock_batch = MagicMock()
        mock_db.batch.return_value = mock_batch
        mock_doc = MagicMock()
        mock_doc.id = "new_doc_id"
        mock_ref = MagicMock()
        mock_ref.document.return_value = mock_doc
        mock_db.collection.return_value.document.return_value.collection.return_value = mock_ref

        payload = {
            "records": [
                {"heart_rate": 72, "spo2": 98, "temperature": 36.5, "recorded_at": "2025-03-20T08:30:00Z"}
            ]
        }
        response = self.client.post(
            reverse('upload_health'),
            data=json.dumps(payload),
            content_type='application/json',
            HTTP_AUTHORIZATION=f'Bearer {self.valid_token}'
        )
        self.assertEqual(response.status_code, 201)
        self.assertIn('record_ids', response.json())
        self.assertEqual(len(response.json()['record_ids']), 1)

    @patch('admin_panel.views.firebase_auth.verify_id_token')
    def test_upload_health_data_no_records(self, mock_verify):
        self._mock_auth(mock_verify)
        response = self.client.post(
            reverse('upload_health'),
            data=json.dumps({"records": []}),
            content_type='application/json',
            HTTP_AUTHORIZATION=f'Bearer {self.valid_token}'
        )
        self.assertEqual(response.status_code, 400)
        self.assertIn('No records provided', response.json()['error'])

    @patch('admin_panel.views.firebase_auth.verify_id_token')
    def test_upload_health_data_invalid_record(self, mock_verify):
        self._mock_auth(mock_verify)
        payload = {"records": [{"heart_rate": 300, "spo2": 98}]}  # heart rate out of range
        response = self.client.post(
            reverse('upload_health'),
            data=json.dumps(payload),
            content_type='application/json',
            HTTP_AUTHORIZATION=f'Bearer {self.valid_token}'
        )
        self.assertEqual(response.status_code, 400)
        self.assertIn('Heart rate', response.json()['error'])

    @patch('admin_panel.views.db')
    @patch('admin_panel.views.firebase_auth.verify_id_token')
    def test_get_history_success(self, mock_verify, mock_db):
        self._mock_auth(mock_verify)
        # Mock Firestore query chain
        mock_query = MagicMock()
        mock_db.collection.return_value.document.return_value.collection.return_value = mock_query
        mock_query.order_by.return_value = mock_query
        mock_query.where.return_value = mock_query
        mock_query.start_after.return_value = mock_query
        mock_docs = [
            MagicMock(id="rec1", to_dict=lambda: {
                "heart_rate": 72, "spo2": 98, "temperature": 36.5,
                "recorded_at": "2025-03-20T08:30:00Z", "uploaded_at": "2025-03-20T08:30:05Z"
            })
        ]
        mock_query.limit.return_value.stream.return_value = mock_docs

        response = self.client.get(
            reverse('get_history'),
            {'limit': 10},
            HTTP_AUTHORIZATION=f'Bearer {self.valid_token}'
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()['count'], 1)
        self.assertEqual(response.json()['records'][0]['heart_rate'], 72)

    @patch('admin_panel.views.db')
    @patch('admin_panel.views.firebase_auth.verify_id_token')
    def test_get_insights_success(self, mock_verify, mock_db):
        self._mock_auth(mock_verify)
        mock_query = MagicMock()
        mock_db.collection.return_value.document.return_value.collection.return_value = mock_query
        mock_query.order_by.return_value = mock_query
        mock_docs = [
            MagicMock(id="ins1", to_dict=lambda: {
                "title": "Test Insight", "summary": "Summary", "detail": "Detail",
                "severity": "normal", "is_premium": False, "generated_at": "2025-03-20T00:00:00Z"
            })
        ]
        mock_query.limit.return_value.stream.return_value = mock_docs

        response = self.client.get(
            reverse('get_insights'),
            HTTP_AUTHORIZATION=f'Bearer {self.valid_token}'
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.json()), 1)
        self.assertEqual(response.json()[0]['title'], 'Test Insight')

    @patch('admin_panel.views.db')
    @patch('admin_panel.views.firebase_auth.verify_id_token')
    def test_update_profile_success(self, mock_verify, mock_db):
        self._mock_auth(mock_verify)
        mock_user_ref = MagicMock()
        mock_db.collection.return_value.document.return_value = mock_user_ref

        payload = {"displayName": "New Name", "settings": {"theme": "dark"}}
        response = self.client.put(
            reverse('update_profile'),
            data=json.dumps(payload),
            content_type='application/json',
            HTTP_AUTHORIZATION=f'Bearer {self.valid_token}'
        )
        self.assertEqual(response.status_code, 200)
        mock_user_ref.update.assert_called_once_with(payload)

    @patch('admin_panel.views.db')
    @patch('admin_panel.views.firebase_auth.verify_id_token')
    def test_subscription_status(self, mock_verify, mock_db):
        self._mock_auth(mock_verify)
        mock_doc = MagicMock()
        mock_doc.exists = True
        mock_doc.to_dict.return_value = {"premium": True, "premiumExpiry": (datetime.now() + timedelta(days=10)).isoformat()}
        mock_db.collection.return_value.document.return_value.get.return_value = mock_doc

        response = self.client.get(
            reverse('subscription_status'),
            HTTP_AUTHORIZATION=f'Bearer {self.valid_token}'
        )
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.json()['premium'])
        self.assertTrue(response.json()['active'])

    @patch('admin_panel.views.db')
    @patch('admin_panel.views.firebase_auth.verify_id_token')
    def test_verify_receipt(self, mock_verify, mock_db):
        self._mock_auth(mock_verify)
        mock_user_ref = MagicMock()
        mock_db.collection.return_value.document.return_value = mock_user_ref
        mock_sub_ref = MagicMock()
        mock_user_ref.collection.return_value.document.return_value = mock_sub_ref

        payload = {"receipt": "fake_receipt", "product_id": "premium_monthly", "platform": "android"}
        response = self.client.post(
            reverse('verify_receipt'),
            data=json.dumps(payload),
            content_type='application/json',
            HTTP_AUTHORIZATION=f'Bearer {self.valid_token}'
        )
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.json()['premium'])
        mock_user_ref.update.assert_called_once()
        mock_sub_ref.set.assert_called_once()

    def test_missing_token(self):
        response = self.client.get(reverse('get_history'))
        self.assertEqual(response.status_code, 401)
        self.assertIn('Missing or invalid Authorization header', response.json()['error'])


# -------------------------------------------------------------------
# Note: Admin UI tests are skipped because Firestore models are not compatible
# with Django's SQL-based admin. Use Firebase Console to manage data.
# -------------------------------------------------------------------