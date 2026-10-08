# generate_hrv_stress_dataset.py

import numpy as np
import pandas as pd
import os

os.makedirs('datasets', exist_ok=True)

np.random.seed(42)

def generate_hrv_stress_dataset(n_samples=200000):
    """Generate realistic HRV and stress dataset"""
    
    data = []
    
    for _ in range(n_samples):
        # Generate realistic stress levels (0-100)
        stress_score = np.random.uniform(0, 100)
        
        # HRV metrics inversely correlated with stress
        # Low stress = high HRV (good), High stress = low HRV (poor)
        base_rmssd = 80 - (stress_score * 0.6)
        base_sdnn = 70 - (stress_score * 0.5)
        base_lfhf = 0.3 + (stress_score * 0.04)
        
        # Add realistic physiological variation
        rmssd = max(10, min(120, base_rmssd + np.random.normal(0, 8)))
        sdnn = max(15, min(100, base_sdnn + np.random.normal(0, 7)))
        lfhf = max(0.1, min(3.0, base_lfhf + np.random.normal(0, 0.2)))
        
        # Add random noise based on measurement quality
        noise_level = np.random.choice(['low', 'medium', 'high'], p=[0.7, 0.2, 0.1])
        if noise_level == 'medium':
            rmssd += np.random.normal(0, 5)
            sdnn += np.random.normal(0, 4)
        elif noise_level == 'high':
            rmssd += np.random.normal(0, 10)
            sdnn += np.random.normal(0, 8)
        
        # Ensure realistic ranges
        rmssd = max(10, min(120, rmssd))
        sdnn = max(15, min(100, sdnn))
        
        # Determine stress level category
        if stress_score < 30:
            stress_category = 'Low'
            recovery_status = 'Excellent recovery'
        elif stress_score < 60:
            stress_category = 'Medium'
            recovery_status = 'Normal recovery'
        else:
            stress_category = 'High'
            recovery_status = 'Poor recovery'
        
        # Add age and gender demographics
        age = np.random.randint(18, 85)
        gender = np.random.choice(['Male', 'Female'])
        bmi = np.random.uniform(18.5, 35)
        
        data.append({
            'rmssd_ms': round(rmssd, 2),
            'sdnn_ms': round(sdnn, 2),
            'lf_hf_ratio': round(lfhf, 3),
            'stress_score': round(stress_score, 1),
            'stress_category': stress_category,
            'recovery_status': recovery_status,
            'age': age,
            'gender': gender,
            'bmi': round(bmi, 1),
            'measurement_quality': noise_level,
            'timestamp': pd.Timestamp.now() - pd.Timedelta(days=np.random.randint(0, 365))
        })
    
    df = pd.DataFrame(data)
    df.to_csv('datasets/hrv_stress_dataset.csv', index=False)
    print(f"✅ Generated {len(df):,} rows for HRV Stress dataset")
    print(f"   Columns: {list(df.columns)}")
    print(f"   Stress distribution: Low={len(df[df.stress_category=='Low']):,}, "
          f"Medium={len(df[df.stress_category=='Medium']):,}, "
          f"High={len(df[df.stress_category=='High']):,}")
    return df

if __name__ == "__main__":
    df = generate_hrv_stress_dataset(200000)
    print("\nSample data:")
    print(df.head(10))