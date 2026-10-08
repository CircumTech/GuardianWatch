# generate_fever_dataset.py

import numpy as np
import pandas as pd
import os

os.makedirs('datasets', exist_ok=True)

np.random.seed(42)

def generate_fever_dataset(n_samples=200000):
    """Generate realistic fever/infection dataset"""
    
    data = []
    
    # Fever prevalence: ~2-5% of measurements
    for _ in range(n_samples):
        # Determine if fever/infection is present
        has_fever = 1 if np.random.random() < 0.04 else 0  # 4% prevalence
        
        # Generate 48 hours of temperature data (samples every 30 min)
        temp_history = []
        hr_history = []
        
        # Baseline temperature (36.0-37.0°C normal range)
        baseline_temp = np.random.uniform(36.2, 36.8)
        
        if has_fever:
            # Fever pattern: gradual rise then decline
            fever_start = np.random.randint(12, 36)
            fever_duration = np.random.randint(6, 24)
            max_temp = np.random.uniform(38.0, 39.5)
            
            for hour in range(48):
                if fever_start <= hour < fever_start + fever_duration:
                    # Fever period
                    progress = (hour - fever_start) / fever_duration
                    temp = baseline_temp + (max_temp - baseline_temp) * np.sin(progress * np.pi)
                    temp += np.random.normal(0, 0.1)
                    
                    # HR increases with fever (~10 bpm per °C)
                    hr = 65 + (temp - baseline_temp) * 15 + np.random.normal(0, 5)
                else:
                    # Normal period
                    temp = baseline_temp + np.random.normal(0, 0.1)
                    hr = np.random.uniform(60, 75) + np.random.normal(0, 3)
                
                temp_history.append(max(35.5, min(41.0, temp)))
                hr_history.append(max(50, min(120, hr)))
            
            current_temp = temp_history[-1]
            fever_probability = min(1.0, (max_temp - baseline_temp) / 1.5)
        else:
            # Normal pattern
            for hour in range(48):
                # Circadian rhythm: lowest in early morning, highest in late afternoon
                circadian = 0.5 * np.sin(2 * np.pi * (hour - 6) / 24)
                temp = baseline_temp + circadian + np.random.normal(0, 0.08)
                hr = 68 + 5 * circadian + np.random.normal(0, 3)
                
                temp_history.append(max(35.5, min(37.5, temp)))
                hr_history.append(max(55, min(85, hr)))
            
            current_temp = temp_history[-1]
            fever_probability = max(0, min(0.3, (current_temp - baseline_temp) / 1.0))
        
        # Calculate features
        mean_temp = np.mean(temp_history)
        temp_variance = np.var(temp_history)
        max_temp = max(temp_history)
        temp_trend = (temp_history[-1] - temp_history[-24]) / 24 if len(temp_history) >= 24 else 0
        
        # HR-temperature correlation
        correlation = np.corrcoef(temp_history[-24:], hr_history[-24:])[0, 1] if len(temp_history) >= 24 else 0
        
        # Symptoms (simulated)
        if has_fever:
            symptoms = ['cough', 'fatigue', 'headache', 'muscle_ache']
            num_symptoms = np.random.randint(1, 4)
            reported_symptoms = ', '.join(np.random.choice(symptoms, num_symptoms, replace=False))
        else:
            reported_symptoms = ''
        
        data.append({
            'baseline_temp': round(baseline_temp, 1),
            'current_temp': round(current_temp, 1),
            'max_temp': round(max_temp, 1),
            'mean_temp': round(mean_temp, 1),
            'temp_variance': round(temp_variance, 3),
            'temp_trend': round(temp_trend, 2),
            'hr_temp_correlation': round(correlation, 3),
            'heart_rate': round(hr_history[-1], 1),
            'fever_probability': round(fever_probability, 2),
            'is_fever_suspected': has_fever,
            'symptoms': reported_symptoms,
            'age': np.random.randint(0, 90),
            'is_child': 1 if np.random.random() < 0.1 and has_fever else 0,
            'vaccinated': np.random.choice([0, 1], p=[0.3, 0.7]) if has_fever else 1
        })
    
    df = pd.DataFrame(data)
    df.to_csv('datasets/fever_dataset.csv', index=False)
    print(f"✅ Generated {len(df):,} rows for Fever/Infection dataset")
    print(f"   Fever prevalence: {df.is_fever_suspected.sum():,} ({df.is_fever_suspected.mean()*100:.1f}%)")
    return df

if __name__ == "__main__":
    df = generate_fever_dataset(200000)
    print("\nSample data:")
    print(df.head(10))