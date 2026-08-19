# generate_sleep_apnea_dataset.py

import numpy as np
import pandas as pd
import os

os.makedirs('datasets', exist_ok=True)

np.random.seed(42)

def generate_sleep_apnea_dataset(n_samples=200000):
    """Generate realistic sleep apnea risk dataset"""
    
    data = []
    
    # Clinical prevalence: 10-30% of adults have sleep apnea
    for _ in range(n_samples):
        # Risk level distribution
        risk_levels = ['Low', 'Medium', 'High']
        risk_probs = [0.6, 0.25, 0.15]  # 60% low, 25% medium, 15% high
        risk_level = np.random.choice(risk_levels, p=risk_probs)
        
        # Generate features based on risk level
        if risk_level == 'Low':
            odi = np.random.uniform(0, 5)
            mean_spo2 = np.random.uniform(94, 98)
            min_spo2 = np.random.uniform(90, 95)
            time_below_90 = np.random.uniform(0, 2)
            hr_std = np.random.uniform(3, 8)
            ahi = odi * 1.1  # AHI slightly higher than ODI
        elif risk_level == 'Medium':
            odi = np.random.uniform(5, 15)
            mean_spo2 = np.random.uniform(91, 95)
            min_spo2 = np.random.uniform(85, 90)
            time_below_90 = np.random.uniform(2, 10)
            hr_std = np.random.uniform(8, 12)
            ahi = odi * 1.15
        else:  # High
            odi = np.random.uniform(15, 40)
            mean_spo2 = np.random.uniform(85, 91)
            min_spo2 = np.random.uniform(75, 85)
            time_below_90 = np.random.uniform(10, 30)
            hr_std = np.random.uniform(12, 20)
            ahi = odi * 1.2
        
        # Add realistic variations
        odi += np.random.normal(0, 0.5)
        mean_spo2 += np.random.normal(0, 0.3)
        min_spo2 += np.random.normal(0, 1)
        time_below_90 += np.random.normal(0, 0.5)
        hr_std += np.random.normal(0, 0.5)
        ahi += np.random.normal(0, 0.5)
        
        # Demographics (sleep apnea is more common in older males with higher BMI)
        if risk_level == 'High':
            age = np.random.randint(45, 75)
            bmi = np.random.uniform(28, 40)
            gender = np.random.choice(['Male', 'Female'], p=[0.7, 0.3])
        elif risk_level == 'Medium':
            age = np.random.randint(35, 65)
            bmi = np.random.uniform(25, 35)
            gender = np.random.choice(['Male', 'Female'], p=[0.6, 0.4])
        else:
            age = np.random.randint(20, 55)
            bmi = np.random.uniform(18.5, 28)
            gender = np.random.choice(['Male', 'Female'], p=[0.5, 0.5])
        
        # Health conditions
        has_hypertension = 1 if risk_level != 'Low' and np.random.random() < 0.4 else 0
        has_diabetes = 1 if risk_level == 'High' and np.random.random() < 0.3 else 0
        
        # Risk score
        risk_score = odi / 30 * 100
        risk_score = min(100, max(0, risk_score))
        
        data.append({
            'odi': round(odi, 1),
            'ahi': round(ahi, 1),  # Apnea-Hypopnea Index (clinical metric)
            'mean_spo2': round(mean_spo2, 1),
            'min_spo2': round(min_spo2, 1),
            'time_below_90_percent': round(time_below_90, 1),
            'heart_rate_std': round(hr_std, 1),
            'risk_level': risk_level,
            'risk_score': round(risk_score, 1),
            'age': age,
            'bmi': round(bmi, 1),
            'gender': gender,
            'has_hypertension': has_hypertension,
            'has_diabetes': has_diabetes,
            'sleep_duration_hours': round(np.random.uniform(5, 9), 1),
            'snoring_frequency': np.random.choice(['Never', 'Occasional', 'Frequent'], 
                                                   p=[0.3, 0.4, 0.3] if risk_level != 'Low' else [0.6, 0.3, 0.1])
        })
    
    df = pd.DataFrame(data)
    df.to_csv('datasets/sleep_apnea_dataset.csv', index=False)
    print(f"✅ Generated {len(df):,} rows for Sleep Apnea dataset")
    print(f"   Risk distribution: Low={len(df[df.risk_level=='Low']):,}, "
          f"Medium={len(df[df.risk_level=='Medium']):,}, "
          f"High={len(df[df.risk_level=='High']):,}")
    return df

if __name__ == "__main__":
    df = generate_sleep_apnea_dataset(200000)
    print("\nSample data:")
    print(df.head(10))