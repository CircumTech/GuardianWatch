# generate_afib_dataset.py

import numpy as np
import pandas as pd
import os

os.makedirs('datasets', exist_ok=True)

np.random.seed(42)

def generate_afib_dataset(n_samples=200000):
    """Generate realistic ECG/AFib dataset"""
    
    data = []
    
    # Generate 10-second ECG segments (250Hz = 2500 points)
    for i in range(n_samples):
        # 80% normal, 20% AFib (prevalence in real-world screening)
        is_afib = 1 if np.random.random() < 0.2 else 0
        
        # Simulate heart rate variability
        if is_afib:
            # AFib: highly irregular, chaotic rhythm
            mean_hr = np.random.uniform(80, 160)
            hr_variability = np.random.uniform(25, 50)
            rr_irregularity = np.random.uniform(0.3, 0.6)
            p_wave_presence = 0
        else:
            # Normal: regular rhythm
            mean_hr = np.random.uniform(55, 100)
            hr_variability = np.random.uniform(5, 15)
            rr_irregularity = np.random.uniform(0.05, 0.15)
            p_wave_presence = 1
        
        # Generate RR intervals
        rr_intervals = []
        for _ in range(100):
            rr = 60000 / (mean_hr + np.random.normal(0, hr_variability))
            if is_afib:
                rr *= (1 + np.random.uniform(-rr_irregularity, rr_irregularity))
            rr_intervals.append(max(300, min(1500, rr)))
        
        # Calculate additional features
        mean_rr = np.mean(rr_intervals)
        std_rr = np.std(rr_intervals)
        cv_rr = std_rr / mean_rr if mean_rr > 0 else 0
        
        # Signal quality metrics
        noise_level = np.random.choice(['low', 'medium', 'high'], p=[0.8, 0.15, 0.05])
        signal_amplitude = np.random.uniform(0.8, 1.5)
        
        # Statistical features
        rmssd = np.sqrt(np.mean(np.square(np.diff(rr_intervals))))
        pnn50 = np.sum(np.abs(np.diff(rr_intervals)) > 50) / len(rr_intervals) * 100
        
        # Classification confidence
        if is_afib:
            confidence = np.random.uniform(0.75, 0.99)
        else:
            confidence = np.random.uniform(0.85, 0.99)
        
        data.append({
            'sample_id': i,
            'is_afib': is_afib,
            'mean_heart_rate': round(mean_hr, 1),
            'rr_irregularity': round(rr_irregularity, 3),
            'mean_rr_ms': round(mean_rr, 1),
            'std_rr_ms': round(std_rr, 2),
            'cv_rr': round(cv_rr, 3),
            'rmssd_ms': round(rmssd, 1),
            'pnn50_percent': round(pnn50, 1),
            'p_wave_presence': p_wave_presence,
            'signal_amplitude_mv': round(signal_amplitude, 2),
            'signal_quality': noise_level,
            'detection_confidence': round(confidence, 3),
            'age': np.random.randint(40, 90) if is_afib else np.random.randint(18, 80),
            'gender': np.random.choice(['Male', 'Female']),
            'has_hypertension': np.random.choice([0, 1], p=[0.7, 0.3]) if is_afib else 0
        })
    
    df = pd.DataFrame(data)
    df.to_csv('datasets/afib_detection_dataset.csv', index=False)
    print(f"✅ Generated {len(df):,} rows for AFib Detection dataset")
    print(f"   AFib prevalence: {df.is_afib.sum():,} ({df.is_afib.mean()*100:.1f}%)")
    print(f"   Normal: {len(df)-df.is_afib.sum():,}")
    return df

if __name__ == "__main__":
    df = generate_afib_dataset(200000)
    print("\nSample data:")
    print(df.head(10))