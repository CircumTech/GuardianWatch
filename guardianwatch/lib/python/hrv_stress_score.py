# ─── hrv_stress_score.py ─────────────────────────────────────────────────────
# Trains a RandomForest model for stress detection from HRV features

import numpy as np
from scipy import signal
from sklearn.ensemble import RandomForestRegressor
from sklearn.model_selection import train_test_split
from sklearn.metrics import mean_absolute_error, r2_score
import joblib
import os

# Create models directory if it doesn't exist
os.makedirs('models', exist_ok=True)

def generate_synthetic_hrv_data(n_samples=5000):
    """
    Generate synthetic HRV data for training.
    In production, replace with real labeled data from WESAD or SWELL-KW datasets.
    """
    np.random.seed(42)
    X = []
    y = []
    
    for _ in range(n_samples):
        # Simulate different stress levels
        stress_level = np.random.uniform(0, 100)
        
        # HRV metrics vary with stress
        # High stress = low RMSSD, low SDNN, high LF/HF ratio
        base_rmssd = 60 - (stress_level * 0.4)
        base_sdnn = 55 - (stress_level * 0.35)
        base_lfhf = 0.5 + (stress_level * 0.03)
        
        # Add noise
        rmssd = max(10, base_rmssd + np.random.normal(0, 8))
        sdnn = max(15, base_sdnn + np.random.normal(0, 7))
        lfhf = max(0.1, base_lfhf + np.random.normal(0, 0.3))
        
        X.append([rmssd, sdnn, lfhf])
        y.append(stress_level + np.random.normal(0, 8))
    
    return np.array(X), np.array(y)

def compute_hrv_features(rr_intervals):
    """Extract HRV features from RR intervals (in milliseconds)"""
    rr_intervals = np.array(rr_intervals)
    diff_rr = np.diff(rr_intervals)
    
    features = {
        'mean_rr': np.mean(rr_intervals),
        'sdnn': np.std(rr_intervals),
        'rmssd': np.sqrt(np.mean(diff_rr**2)),
        'pnn50': np.sum(np.abs(diff_rr) > 50) / len(diff_rr) * 100 if len(diff_rr) > 0 else 0,
        'lf_power': 0,
        'hf_power': 0,
        'lf_hf_ratio': 0,
    }
    
    # Frequency domain calculation
    if len(rr_intervals) > 30:
        try:
            # Interpolate to even sampling
            t = np.cumsum(rr_intervals) / 1000.0
            if len(t) > 1:
                t_uniform = np.linspace(t[0], t[-1], len(rr_intervals))
                rr_uniform = np.interp(t_uniform, t, rr_intervals)
                
                # Detrend
                rr_detrended = rr_uniform - np.mean(rr_uniform)
                
                # Compute Lomb-Scargle periodogram
                freqs = np.linspace(0.003, 0.4, 500)
                periodogram = signal.lombscargle(t_uniform, rr_detrended, 2 * np.pi * freqs)
                periodogram = np.sqrt(periodogram / len(t_uniform))
                
                lf_mask = (freqs >= 0.04) & (freqs < 0.15)
                hf_mask = (freqs >= 0.15) & (freqs < 0.4)
                
                features['lf_power'] = np.sum(periodogram[lf_mask])
                features['hf_power'] = np.sum(periodogram[hf_mask])
                features['lf_hf_ratio'] = features['lf_power'] / (features['hf_power'] + 1e-6)
        except Exception as e:
            print(f"Frequency domain calculation failed: {e}")
    
    return features

def train_stress_model():
    """Train RandomForestRegressor for stress score prediction"""
    print("Generating synthetic training data...")
    X, y = generate_synthetic_hrv_data(5000)
    
    # Split data
    X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)
    
    # Train model
    print("Training RandomForestRegressor...")
    model = RandomForestRegressor(
        n_estimators=100,
        max_depth=10,
        min_samples_split=5,
        min_samples_leaf=2,
        random_state=42,
        n_jobs=-1
    )
    model.fit(X_train, y_train)
    
    # Evaluate
    y_pred = model.predict(X_test)
    mae = mean_absolute_error(y_test, y_pred)
    r2 = r2_score(y_test, y_pred)
    
    print(f"✅ Stress Model - MAE: {mae:.2f}, R²: {r2:.3f}")
    
    # Save model
    joblib.dump(model, '../assets/models/stress_model.pkl')
    print("✅ Model saved to ../assets/models/stress_model.pkl")
    
    return model

def predict_stress(rr_intervals, model=None):
    """Predict stress level from RR intervals"""
    if model is None:
        model = joblib.load('../assets/models/stress_model.pkl')
    
    features = compute_hrv_features(rr_intervals)
    feature_vector = np.array([[features['rmssd'], features['sdnn'], features['lf_hf_ratio']]])
    stress_score = model.predict(feature_vector)[0]
    stress_score = max(0, min(100, stress_score))
    
    if stress_score < 30:
        stress_level = "Low"
        recovery_status = "Excellent recovery"
    elif stress_score < 60:
        stress_level = "Medium"
        recovery_status = "Normal recovery"
    else:
        stress_level = "High"
        recovery_status = "Poor recovery"
    
    return {
        "stress_score": round(float(stress_score), 1),
        "stress_level": stress_level,
        "hrv_rmssd": round(features['rmssd'], 1),
        "hrv_sdnn": round(features['sdnn'], 1),
        "lf_hf_ratio": round(features['lf_hf_ratio'], 2),
        "recovery_status": recovery_status,
        "recommendation": "Try deep breathing exercises" if stress_score > 50 else "Maintain your healthy routine"
    }

if __name__ == "__main__":
    # Train and save the model
    model = train_stress_model()
    
    # Test with sample data
    sample_rr = [800, 805, 810, 795, 800, 820, 815, 805, 790, 810]
    result = predict_stress(sample_rr, model)
    print("\nSample prediction:")
    for k, v in result.items():
        print(f"  {k}: {v}")