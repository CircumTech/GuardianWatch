# ─── sleep_apnea.py ─────────────────────────────────────────────────────────
# Trains XGBoost model for Sleep Apnea risk classification

import numpy as np
import xgboost as xgb
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import StandardScaler
from sklearn.metrics import classification_report, confusion_matrix
import joblib
import os

os.makedirs('models', exist_ok=True)

def generate_synthetic_sleep_data(n_samples=3000):
    """
    Generate synthetic sleep data for training.
    Features: ODI, mean SpO2, min SpO2, time below 90%, HR std, age, BMI
    Target: 0=Low risk, 1=Medium risk, 2=High risk
    """
    np.random.seed(42)
    X = []
    y = []
    
    for _ in range(n_samples):
        # Generate risk level
        risk_level = np.random.choice([0, 1, 2], p=[0.5, 0.3, 0.2])
        
        # Features vary with risk level
        if risk_level == 0:  # Low risk
            odi = np.random.uniform(0, 5)
            mean_spo2 = np.random.uniform(94, 98)
            min_spo2 = np.random.uniform(90, 95)
            time_below_90 = np.random.uniform(0, 2)
            hr_std = np.random.uniform(3, 8)
        elif risk_level == 1:  # Medium risk
            odi = np.random.uniform(5, 15)
            mean_spo2 = np.random.uniform(91, 95)
            min_spo2 = np.random.uniform(85, 90)
            time_below_90 = np.random.uniform(2, 10)
            hr_std = np.random.uniform(8, 12)
        else:  # High risk
            odi = np.random.uniform(15, 40)
            mean_spo2 = np.random.uniform(85, 91)
            min_spo2 = np.random.uniform(75, 85)
            time_below_90 = np.random.uniform(10, 30)
            hr_std = np.random.uniform(12, 20)
        
        age = np.random.uniform(20, 80)
        bmi = np.random.uniform(18, 40)
        
        # Add noise
        odi += np.random.normal(0, 0.5)
        mean_spo2 += np.random.normal(0, 0.3)
        min_spo2 += np.random.normal(0, 1)
        time_below_90 += np.random.normal(0, 0.5)
        hr_std += np.random.normal(0, 0.5)
        
        X.append([odi, mean_spo2, min_spo2, time_below_90, hr_std, age/100, bmi/40])
        y.append(risk_level)
    
    return np.array(X), np.array(y)

def compute_odi(spo2_night, sampling_rate_hz=1):
    """Compute Oxygen Desaturation Index"""
    if len(spo2_night) < 100:
        return 0
    
    spo2 = np.array(spo2_night)
    baseline = np.mean(spo2[:min(100, len(spo2))])
    
    desaturations = 0
    i = 0
    while i < len(spo2):
        if spo2[i] < baseline - 3:
            desaturations += 1
            # Skip to end of desaturation
            i += 10  # Approximate skip
        i += 1
    
    hours = len(spo2) / (sampling_rate_hz * 3600)
    odi = desaturations / max(hours, 1)
    
    return odi

def train_sleep_apnea_model():
    """Train XGBoost classifier for sleep apnea risk"""
    print("Generating synthetic training data...")
    X, y = generate_synthetic_sleep_data(5000)
    
    # Split data
    X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42, stratify=y)
    
    # Scale features
    scaler = StandardScaler()
    X_train_scaled = scaler.fit_transform(X_train)
    X_test_scaled = scaler.transform(X_test)
    
    # Train model
    print("Training XGBoost classifier...")
    model = xgb.XGBClassifier(
        n_estimators=100,
        max_depth=6,
        learning_rate=0.1,
        objective='multi:softprob',
        eval_metric='mlogloss',
        random_state=42,
        use_label_encoder=False
    )
    
    model.fit(X_train_scaled, y_train)
    
    # Evaluate
    y_pred = model.predict(X_test_scaled)
    accuracy = np.mean(y_pred == y_test)
    
    print(f"\n✅ Sleep Apnea Model - Accuracy: {accuracy:.3f}")
    print(classification_report(y_test, y_pred, target_names=['Low Risk', 'Medium Risk', 'High Risk']))
    print("Confusion Matrix:")
    print(confusion_matrix(y_test, y_pred))
    
    # Save model and scaler
    joblib.dump(model, '../assets/models/sleep_apnea_model.pkl')
    joblib.dump(scaler, '../assets/models/sleep_apnea_scaler.pkl')
    print("✅ Model saved to ../assets/models/sleep_apnea_model.pkl")
    
    return model, scaler

def predict_sleep_apnea(spo2_night, hr_night=None, age=30, bmi=24, sampling_rate_hz=1, model=None, scaler=None):
    """Predict sleep apnea risk from overnight SpO2 data"""
    if model is None:
        model = joblib.load('../assets/models/sleep_apnea_model.pkl')
        scaler = joblib.load('../assets/models/sleep_apnea_scaler.pkl')
    
    odi = compute_odi(spo2_night, sampling_rate_hz)
    mean_spo2 = np.mean(spo2_night)
    min_spo2 = np.min(spo2_night)
    time_below_90 = np.sum(np.array(spo2_night) < 90) / len(spo2_night) * 100
    
    if hr_night is not None and len(hr_night) > 0:
        hr_std = np.std(hr_night)
    else:
        hr_std = 8  # Default
    
    features = np.array([[odi, mean_spo2, min_spo2, time_below_90, hr_std, age/100, bmi/40]])
    features_scaled = scaler.transform(features)
    
    risk_proba = model.predict_proba(features_scaled)[0]
    risk_class = np.argmax(risk_proba)
    
    risk_score = risk_proba[2] * 100  # High risk probability * 100
    
    if risk_class == 0:
        risk_level = "Low"
        recommendation = "Your sleep breathing appears normal."
    elif risk_class == 1:
        risk_level = "Medium"
        recommendation = "Consider sleeping on your side and maintaining a healthy weight."
    else:
        risk_level = "High"
        recommendation = "Consult a doctor about a sleep study."
    
    return {
        "odi": round(odi, 1),
        "risk_score": round(risk_score, 1),
        "risk_level": risk_level,
        "recommendation": recommendation,
        "class_probabilities": risk_proba.tolist()
    }

if __name__ == "__main__":
    model, scaler = train_sleep_apnea_model()
    
    # Test with sample data
    sample_spo2 = [96, 95, 94, 93, 92, 91, 90, 92, 94, 96] * 100
    result = predict_sleep_apnea(sample_spo2, age=45, bmi=28)
    print(f"\nSample prediction: {result}")