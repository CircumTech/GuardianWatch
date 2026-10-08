# generate_all_datasets.py

import subprocess
import os

def generate_all_datasets():
    """Generate all 200k row datasets"""
    
    scripts = [
        ("HRV Stress", "generate_hrv_stress_dataset.py"),
        ("AFib Detection", "generate_afib_dataset.py"),
        ("Sleep Apnea", "generate_sleep_apnea_dataset.py"),
        ("Fever/Infection", "generate_fever_dataset.py"),
        ("Fatigue/Overtraining", "generate_fatigue_dataset.py"),
    ]
    
    os.makedirs('datasets', exist_ok=True)
    
    for name, script in scripts:
        print(f"\n{'='*50}")
        print(f"Generating {name} dataset...")
        print(f"{'='*50}")
        
        if os.path.exists(script):
            subprocess.run(['python', script])
        else:
            print(f"❌ {script} not found!")
    
    print("\n" + "="*50)
    print("✅ All datasets generated successfully!")
    print(f"📁 Datasets saved in 'datasets/' directory")
    
    # Show file sizes
    print("\n📊 File sizes:")
    for file in os.listdir('datasets'):
        if file.endswith('.csv'):
            size = os.path.getsize(f'datasets/{file}') / (1024 * 1024)
            print(f"   {file}: {size:.1f} MB")

if __name__ == "__main__":
    generate_all_datasets()