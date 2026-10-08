# ─── fatigue_monitor.py ──────────────────────────────────────────────────────
# Trains Linear Regression model for fatigue/overtraining detection

import numpy as np
from sklearn.linear_model import LinearRegression
from sklearn.model_selection import train_test_split
from sklearn.metrics import mean_absolute_error, r2_score
import joblib
import os

os.makedirs('models', exist_ok=True)

def generate_synthetic_fatigue_data(n_samples=2000):
    """
    Generate synthetic fatigue data.
    Features: [resting_hr, hr_recovery, sleep_hours, previous_day_fatigue]
    Target: fatigue_score (0-100)
    """
    np.random.seed(42)
    X = []
    y = []
    
    for _ in range(n_samples):
        # Generate base features
        resting_hr = np.random.uniform(55, 85)
        hr_recovery = np.random.uniform(10, 35)  # bpm drop after 1 min exercise
        sleep_hours = np.random.uniform(4, 9)
        
        # Previous day fatigue influences current fatigue
        prev_fatigue = np.random.uniform(0, 100)
        
        # Calculate fatigue score (higher = more fatigue)
        # Low resting HR = less fatigue, but increased resting HR = more fatigue
        hr_normalized = (resting_hr - 55) / 30
        hr_component = hr_normalized * 30
        
        # Poor recovery = more fatigue
        recovery_normalized = max(0, (35 - hr_recovery) / 25)
        recovery_component = recovery_normalized * 30
        
        # Less sleep = more fatigue
        sleep_component = max(0, (7 - sleep_hours) * 15)
        
        # Previous fatigue carries over (inertia)
        fatigue_inertia = prev_fatigue * 0.2
        
        fatigue_score = (
            hr_component +
            recovery_component +
            sleep_component +
            fatigue_inertia +
            np.random.normal(0, 5)  # random noise
        )
        fatigue_score = max(0, min(100, fatigue_score))
        
        X.append([resting_hr, hr_recovery, sleep_hours, prev_fatigue])
        y.append(fatigue_score)
    
    return np.array(X), np.array(y)

def train_fatigue_model():
    """Train Linear Regression for fatigue index prediction"""
    print("Generating synthetic training data...")
    X, y = generate_synthetic_fatigue_data(5000)
    
    # Split data
    X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)
    
    # Train model
    print("Training Linear Regression model...")
    model = LinearRegression()
    model.fit(X_train, y_train)
    
    # Evaluate
    y_pred = model.predict(X_test)
    mae = mean_absolute_error(y_test, y_pred)
    r2 = r2_score(y_test, y_pred)
    
    print(f"✅ Fatigue Model - MAE: {mae:.2f}, R²: {r2:.3f}")
    print(f"   Coefficients: {model.coef_}")
    print(f"   Intercept: {model.intercept_:.2f}")
    
    # Save model
    joblib.dump(model, '../assets/fatigue_model.pkl')
    print("✅ Model saved to ../assets/models/fatigue_model.pkl")
    
    return model

def compute_fatigue(resting_hr_trend, hr_recovery=None, sleep_hours=7, model=None):
    """
    Compute fatigue score from resting HR trend and recovery data
    resting_hr_trend: list of last 7 days' morning resting HR
    hr_recovery: HR decrease (bpm) 1 minute after exercise (optional)
    sleep_hours: hours of sleep last night
    """
    if model is None:
        model = joblib.load('../assets/models/fatigue_model.pkl')
    
    if len(resting_hr_trend) < 3:
        return {
            "fatigue_score": 50,
            "readiness": "Insufficient data",
            "resting_hr_trend": "Need more data",
            "recommendation": "Continue wearing your watch to establish baseline"
        }
    
    baseline_hr = np.mean(resting_hr_trend[:3])
    current_hr = resting_hr_trend[-1]
    
    if hr_recovery is None:
        hr_recovery = 20  # Default assumed good recovery
    
    # Previous day fatigue (estimate from trend)
    if len(resting_hr_trend) > 1:
        hr_increase = (current_hr - baseline_hr) / baseline_hr
        prev_fatigue = min(100, max(0, hr_increase * 200))
    else:
        prev_fatigue = 30
    
    # Predict fatigue score
    features = np.array([[current_hr, hr_recovery, sleep_hours, prev_fatigue]])
    fatigue_score = float(model.predict(features)[0])
    fatigue_score = max(0, min(100, fatigue_score))
    
    hr_trend_text = f"{baseline_hr:.0f} → {current_hr:.0f} bpm"
    increase_text = f" ({'+' if current_hr > baseline_hr else ''}{current_hr - baseline_hr:.0f} bpm)"
    
    if fatigue_score < 30:
        readiness = "High - Ready for intense workout"
        recommendation = "Great recovery! You're ready for peak performance."
    elif fatigue_score < 60:
        readiness = "Moderate - Light exercise recommended"
        recommendation = "Take it easy today. A light walk or stretching is ideal."
    else:
        readiness = "Low - Rest day recommended"
        recommendation = "Prioritize sleep and recovery. Your body needs rest."
    
    return {
        "fatigue_score": round(fatigue_score, 1),
        "readiness": readiness,
        "resting_hr_trend": hr_trend_text + increase_text,
        "recommendation": recommendation
    }

if __name__ == "__main__":
    model = train_fatigue_model()
    
    # Test with well-rested athlete
    rested_hr = [58, 57, 59, 58, 56, 57, 56]
    result = compute_fatigue(rested_hr, hr_recovery=30, sleep_hours=8, model=model)
    print(f"\nWell-rested athlete: {result}")
    
    # Test with fatigued athlete
    fatigued_hr = [58, 59, 62, 65, 68, 70, 72]
    result = compute_fatigue(fatigued_hr, hr_recovery=15, sleep_hours=5, model=model)
    print(f"\nFatigued athlete: {result}")