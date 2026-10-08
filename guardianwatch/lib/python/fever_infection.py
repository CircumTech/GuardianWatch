# ─── fever_infection.py ──────────────────────────────────────────────────────
# Trains Isolation Forest for fever/infection detection

import numpy as np
from sklearn.ensemble import IsolationForest
from sklearn.model_selection import train_test_split
from sklearn.metrics import classification_report
import joblib
import os

os.makedirs('models', exist_ok=True)

def generate_synthetic_temperature_data(n_samples=3000):
    """
    Generate synthetic temperature and HR data.
    Features: [temperature, temp_rate_of_change, heart_rate, hr_temp_correlation]
    """
    np.random.seed(42)
    X = []
    y = []
    
    for _ in range(n_samples):
        # Determine if normal (0) or fever/infection (1)
        is_anomaly = 1 if np.random.random() < 0.1 else 0  # 10% anomalies
        
        if is_anomaly:
            # Fever: elevated temperature + elevated HR
            temperature = np.random.uniform(37.5, 39.5)
            temp_rate = np.random.uniform(0.05, 0.3)
            heart_rate = 75 + (temperature - 37) * 15 + np.random.normal(0, 5)
            correlation = np.random.uniform(0.6, 0.9)
        else:
            # Normal
            temperature = np.random.uniform(36.0, 37.2)
            temp_rate = np.random.uniform(-0.05, 0.05)
            heart_rate = np.random.uniform(60, 75)
            correlation = np.random.uniform(0.1, 0.4)
        
        X.append([temperature, temp_rate, heart_rate, correlation])
        y.append(is_anomaly)
    
    return np.array(X), np.array(y)

def train_fever_detector():
    """Train Isolation Forest for anomaly detection"""
    print("Generating synthetic training data...")
    X, y = generate_synthetic_temperature_data(5000)
    
    # Filter only normal data for training
    X_normal = X[y == 0]
    print(f"Training on {len(X_normal)} normal samples")
    
    # Train Isolation Forest
    print("Training Isolation Forest...")
    model = IsolationForest(
        contamination=0.05,
        random_state=42,
        n_estimators=100
    )
    model.fit(X_normal)
    
    # Evaluate
    y_pred = model.predict(X)
    y_pred_binary = [1 if p == -1 else 0 for p in y_pred]
    
    accuracy = np.mean(y_pred_binary == y)
    print(f"✅ Fever Detector - Accuracy: {accuracy:.3f}")
    print(classification_report(y, y_pred_binary, target_names=['Normal', 'Fever/Infection']))
    
    # Save model
    joblib.dump(model, '../assets/models/fever_detector.pkl')
    print("✅ Model saved to ../assets/models/fever_detector.pkl")
    
    return model

def detect_fever(temperature_history, hr_history=None):
    """
    Detect fever/infection from temperature and heart rate history
    temperature_history: list of last 24h temps (samples every 30 min)
    hr_history: list of corresponding heart rates (optional)
    """
    if len(temperature_history) < 24:
        return {
            "temperature": temperature_history[-1] if temperature_history else 0,
            "baseline_temp": 0,
            "fever_probability": 0,
            "is_fever_suspected": False,
            "recommendation": "Need more data (at least 24 hours)"
        }
    
    model = joblib.load('../assets/models/fever_detector.pkl')
    
    baseline_temp = np.mean(temperature_history[:24])  # First 12 hours as baseline
    current_temp = temperature_history[-1]
    
    # Temperature rate of change (last 2 hours)
    if len(temperature_history) >= 4:
        temp_rate = (temperature_history[-1] - temperature_history[-4]) / 4
    else:
        temp_rate = 0
    
    if hr_history and len(hr_history) >= 24:
        current_hr = hr_history[-1]
        # Correlation between temp and HR in last 24 hours
        if len(temperature_history) == len(hr_history):
            correlation = np.corrcoef(temperature_history[-24:], hr_history[-24:])[0, 1]
            correlation = max(0, correlation)  # Only positive correlation matters
        else:
            correlation = 0.3
    else:
        # Estimate HR from temperature
        current_hr = 60 + (current_temp - 36.5) * 10
        correlation = 0.3
    
    features = np.array([[current_temp, temp_rate, current_hr, correlation]])
    
    # Predict anomaly (-1 = anomaly, 1 = normal)
    prediction = model.predict(features)[0]
    is_suspected = prediction == -1
    
    # Calculate probability based on anomaly score
    scores = model.decision_function(features)
    if len(scores) > 0:
        probability = 1 / (1 + np.exp(scores[0])) if scores[0] < 0 else 1 / (1 + np.exp(-scores[0]))
        probability = min(1.0, max(0.0, probability))
    else:
        probability = 0.5 if is_suspected else 0.2
    
    if is_suspected:
        recommendation = "Rest, hydrate, and monitor your temperature. Consult a doctor if it persists."
    else:
        recommendation = "Your temperature is within normal range."
    
    return {
        "temperature": round(current_temp, 1),
        "baseline_temp": round(baseline_temp, 1),
        "fever_probability": round(float(probability), 2),
        "is_fever_suspected": bool(is_suspected),
        "recommendation": recommendation
    }

if __name__ == "__main__":
    model = train_fever_detector()
    
    # Test with normal sample
    normal_temps = [36.5, 36.6, 36.5, 36.4, 36.5, 36.6] * 4
    result = detect_fever(normal_temps)
    print(f"\nNormal sample: {result}")
    
    # Test with fever sample
    fever_temps = [36.5, 36.6, 36.5, 37.2, 37.8, 38.2] * 4
    result = detect_fever(fever_temps)
    print(f"\nFever sample: {result}")