# ─── train_all_models.py ─────────────────────────────────────────────────────
# Run this file to train and export all 5 models

import os
import sys

def main():
    print("=" * 60)
    print("Training GuardianWrist Health Insights Models")
    print("=" * 60)
    
    models = [
        ("HRV Stress Model", "hrv_stress_score.py"),
        ("AFib Detection Model", "afib_detection.py"),
        ("Sleep Apnea Model", "sleep_apnea.py"),
        ("Fever Detection Model", "fever_infection.py"),
        ("Fatigue Monitor Model", "fatigue_monitor.py"),
    ]
    
    for name, file in models:
        print(f"\n{'='*40}")
        print(f"Training {name}...")
        print(f"{'='*40}")
        
        if not os.path.exists(file):
            print(f"❌ {file} not found! Skipping.")
            continue
        
        # Run the training script
        exit_code = os.system(f"python {file}")
        if exit_code != 0:
            print(f"❌ Failed to train {name}")
        else:
            print(f"✅ {name} trained successfully")
    
    print("\n" + "=" * 60)
    print("All models training completed!")
    print("Models saved in '../assets/models/' directory")
    print("=" * 60)

if __name__ == "__main__":
    main()