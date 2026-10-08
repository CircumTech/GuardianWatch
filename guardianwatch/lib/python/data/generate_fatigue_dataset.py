# generate_fatigue_dataset.py

import numpy as np
import pandas as pd
import os

os.makedirs('datasets', exist_ok=True)

np.random.seed(42)

def generate_fatigue_dataset(n_samples=200000):
    """Generate realistic fatigue/overtraining dataset"""
    
    data = []
    
    for _ in range(n_samples):
        # Generate 7-day resting HR trend
        baseline_hr = np.random.uniform(55, 70)
        hr_values = [baseline_hr]
        
        # Determine fatigue level based on trend
        fatigue_cause = np.random.choice(['normal', 'recovering', 'fatigued', 'overtrained'], 
                                          p=[0.6, 0.2, 0.15, 0.05])
        
        for day in range(1, 7):
            if fatigue_cause == 'fatigued':
                # Gradual HR increase (fatigue)
                delta = np.random.uniform(0.5, 2.5)
            elif fatigue_cause == 'overtrained':
                # Sharp HR increase
                delta = np.random.uniform(2, 5)
            elif fatigue_cause == 'recovering':
                # HR decreasing (recovery)
                delta = -np.random.uniform(0.5, 2)
            else:
                # Normal variation
                delta = np.random.uniform(-1.5, 1.5)
            
            new_hr = max(45, min(95, hr_values[-1] + delta + np.random.normal(0, 0.5)))
            hr_values.append(new_hr)
        
        current_hr = hr_values[-1]
        hr_increase = (current_hr - baseline_hr) / baseline_hr * 100
        
        # Simulate sleep quality
        if fatigue_cause in ['fatigued', 'overtrained']:
            sleep_hours = np.random.uniform(4, 7)
            sleep_quality = np.random.uniform(2, 6) / 10
        else:
            sleep_hours = np.random.uniform(6.5, 9)
            sleep_quality = np.random.uniform(6, 9) / 10
        
        # HR recovery after exercise (bpm drop after 1 min)
        if fatigue_cause == 'overtrained':
            hr_recovery = np.random.uniform(5, 15)  # Poor recovery
        elif fatigue_cause == 'fatigued':
            hr_recovery = np.random.uniform(12, 22)
        elif fatigue_cause == 'recovering':
            hr_recovery = np.random.uniform(22, 35)
        else:
            hr_recovery = np.random.uniform(15, 28)
        
        # Calculate fatigue score
        hr_component = min(50, max(0, hr_increase * 1.5))
        recovery_component = min(30, max(0, (25 - hr_recovery) * 2))
        sleep_component = min(20, max(0, (7 - sleep_hours) * 8))
        
        fatigue_score = hr_component + recovery_component + sleep_component + np.random.normal(0, 5)
        fatigue_score = max(0, min(100, fatigue_score))
        
        # Determine readiness
        if fatigue_score < 30:
            readiness = 'High'
            recommendation = 'Ready for intense workout'
        elif fatigue_score < 60:
            readiness = 'Moderate'
            recommendation = 'Light exercise recommended'
        else:
            readiness = 'Low'
            recommendation = 'Rest day recommended'
        
        # Training load (estimated)
        if fatigue_cause in ['fatigued', 'overtrained']:
            training_load = np.random.uniform(70, 100)
        elif fatigue_cause == 'recovering':
            training_load = np.random.uniform(20, 50)
        else:
            training_load = np.random.uniform(40, 75)
        
        data.append({
            'baseline_hr_bpm': round(baseline_hr, 1),
            'current_hr_bpm': round(current_hr, 1),
            'hr_increase_percent': round(hr_increase, 1),
            'hr_recovery_1min_bpm': round(hr_recovery, 1),
            'sleep_hours': round(sleep_hours, 1),
            'sleep_quality_score': round(sleep_quality, 2),
            'fatigue_score': round(fatigue_score, 1),
            'readiness': readiness,
            'recommendation': recommendation,
            'training_load_percent': round(training_load, 1),
            'fatigue_cause': fatigue_cause,
            'hr_trend': '-'.join([str(round(h, 1)) for h in hr_values]),
            'age': np.random.randint(18, 50),
            'athlete_type': np.random.choice(['recreational', 'amateur', 'professional'], 
                                              p=[0.5, 0.3, 0.2]),
            'resting_hr_variability': round(np.std(hr_values), 1)
        })
    
    df = pd.DataFrame(data)
    df.to_csv('datasets/fatigue_dataset.csv', index=False)
    print(f"✅ Generated {len(df):,} rows for Fatigue/Overtraining dataset")
    print(f"   Fatigue distribution: Normal={len(df[df.fatigue_cause=='normal']):,}, "
          f"Recovering={len(df[df.fatigue_cause=='recovering']):,}, "
          f"Fatigued={len(df[df.fatigue_cause=='fatigued']):,}, "
          f"Overtrained={len(df[df.fatigue_cause=='overtrained']):,}")
    return df

if __name__ == "__main__":
    df = generate_fatigue_dataset(200000)
    print("\nSample data:")
    print(df.head(10))