# ─── afib_detection.py ───────────────────────────────────────────────────────
# Trains a 1D CNN for Atrial Fibrillation detection from ECG

import numpy as np
import tensorflow as tf
from tensorflow.keras import layers, models
from sklearn.model_selection import train_test_split
from sklearn.metrics import classification_report, roc_auc_score
import os
import json

os.makedirs('models', exist_ok=True)

def generate_synthetic_ecg_data(n_samples=2000, input_length=2500):
    """
    Generate synthetic ECG data for training.
    In production, replace with real data from MIT-BIH AFib Database.
    """
    np.random.seed(42)
    X = []
    y = []
    
    for i in range(n_samples):
        t = np.linspace(0, 10, input_length)  # 10 seconds
        # Simulate normal ECG (0) or AFib (1)
        is_afib = 1 if i >= n_samples // 2 else 0
        
        if is_afib:
            # AFib: irregular, chaotic signal
            signal = 0.5 * np.sin(2 * np.pi * 1.5 * t)
            signal += 0.3 * np.sin(2 * np.pi * 2.0 * t + np.random.uniform(0, 2*np.pi))
            signal += np.random.normal(0, 0.2, input_length)
        else:
            # Normal: regular rhythm with P-QRS-T complex
            signal = np.zeros(input_length)
            for j in range(int(len(t) / 0.8)):  # ~75 bpm
                pos = int(j * 0.8 * 250)
                if pos + 150 < input_length:
                    # P wave
                    signal[pos:pos+50] += 0.15 * np.sin(np.linspace(0, np.pi, 50))
                    # QRS complex
                    qrs_start = pos + 60
                    if qrs_start + 40 < input_length:
                        signal[qrs_start:qrs_start+40] += np.array([0.1, 0.3, 0.8, 1.2, 0.8, 0.3, -0.2, -0.1] * 5)[:40]
                    # T wave
                    t_start = pos + 110
                    if t_start + 40 < input_length:
                        signal[t_start:t_start+40] += 0.2 * np.sin(np.linspace(0, np.pi, 40))
            
            signal += np.random.normal(0, 0.05, input_length)
        
        # Normalize
        signal = (signal - np.mean(signal)) / (np.std(signal) + 1e-6)
        X.append(signal.reshape(-1, 1))
        y.append(is_afib)
    
    return np.array(X), np.array(y)

def build_ecg_cnn(input_length=2500):
    """1D CNN for AFib detection from raw ECG"""
    inputs = tf.keras.Input(shape=(input_length, 1))
    
    # First convolutional block
    x = layers.Conv1D(32, kernel_size=5, activation='relu', padding='same')(inputs)
    x = layers.BatchNormalization()(x)
    x = layers.MaxPooling1D(pool_size=2)(x)
    x = layers.Dropout(0.2)(x)
    
    # Second block
    x = layers.Conv1D(64, kernel_size=5, activation='relu', padding='same')(x)
    x = layers.BatchNormalization()(x)
    x = layers.MaxPooling1D(pool_size=2)(x)
    x = layers.Dropout(0.2)(x)
    
    # Third block
    x = layers.Conv1D(128, kernel_size=5, activation='relu', padding='same')(x)
    x = layers.BatchNormalization()(x)
    x = layers.GlobalAveragePooling1D()(x)
    
    # Dense layers
    x = layers.Dense(64, activation='relu')(x)
    x = layers.Dropout(0.5)(x)
    x = layers.Dense(32, activation='relu')(x)
    x = layers.Dropout(0.3)(x)
    outputs = layers.Dense(1, activation='sigmoid')(x)
    
    model = models.Model(inputs, outputs)
    model.compile(
        optimizer=tf.keras.optimizers.Adam(learning_rate=0.001),
        loss='binary_crossentropy',
        metrics=['accuracy', tf.keras.metrics.AUC(name='auc')]
    )
    
    return model

def preprocess_ecg_segment(ecg_segment, target_length=2500):
    """Preprocess ECG segment for inference"""
    # Resample to target length if needed
    if len(ecg_segment) != target_length:
        x_old = np.linspace(0, 1, len(ecg_segment))
        x_new = np.linspace(0, 1, target_length)
        ecg_segment = np.interp(x_new, x_old, ecg_segment)
    
    # Simple bandpass filter simulation
    ecg_segment = ecg_segment - np.mean(ecg_segment)
    # Normalize
    ecg_segment = ecg_segment / (np.std(ecg_segment) + 1e-6)
    
    return ecg_segment

def train_afib_model():
    """Train CNN for AFib detection and export to TFLite"""
    print("Generating synthetic training data...")
    X, y = generate_synthetic_ecg_data(4000)
    
    # Split data
    X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)
    
    print(f"Training data shape: {X_train.shape}")
    print(f"Test data shape: {X_test.shape}")
    
    # Build model
    model = build_ecg_cnn()
    model.summary()
    
    # Train
    print("Training CNN model...")
    history = model.fit(
        X_train, y_train,
        epochs=20,
        batch_size=64,
        validation_split=0.2,
        class_weight={0: 1.0, 1: 1.5},
        verbose=1
    )
    
    # Evaluate
    y_pred_proba = model.predict(X_test).flatten()
    y_pred = (y_pred_proba > 0.5).astype(int)
    
    auc = roc_auc_score(y_test, y_pred_proba)
    accuracy = np.mean(y_pred == y_test)
    
    print(f"\n✅ AFib Model - Accuracy: {accuracy:.3f}, AUC: {auc:.3f}")
    print(classification_report(y_test, y_pred, target_names=['Normal', 'AFib']))
    
    # Save Keras model
    model.save('../assets/models/afib_detection.h5')
    print("✅ Model saved to ../assets/models/afib_detection.h5")
    
    # Convert to TensorFlow Lite
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    tflite_model = converter.convert()
    
    with open('../assets/models/afib_detection.tflite', 'wb') as f:
        f.write(tflite_model)
    print("✅ TFLite model saved to ../assets/models/afib_detection.tflite")
    
    # Save metadata
    metadata = {
        'input_length': 2500,
        'sampling_rate': 250,
        'duration_seconds': 10,
        'accuracy': float(accuracy),
        'auc': float(auc)
    }
    with open('../assets/models/afib_metadata.json', 'w') as f:
        json.dump(metadata, f, indent=2)
    
    return model

def predict_afib(ecg_segment, model=None):
    """Predict AFib from ECG segment"""
    if model is None:
        model = tf.keras.models.load_model('../assets/models/afib_detection.h5')
    
    # Preprocess
    processed = preprocess_ecg_segment(ecg_segment)
    input_tensor = processed.reshape(1, -1, 1).astype(np.float32)
    
    # Predict
    probability = float(model.predict(input_tensor, verbose=0)[0][0])
    is_afib = probability > 0.5
    
    if probability > 0.8:
        confidence = "High"
    elif probability > 0.6:
        confidence = "Medium"
    else:
        confidence = "Low"
    
    return {
        "afib_probability": round(probability, 3),
        "is_afib_suspected": is_afib,
        "confidence": confidence,
        "recommendation": "Consult a doctor for proper ECG evaluation" if is_afib else "Normal rhythm detected"
    }

if __name__ == "__main__":
    model = train_afib_model()
    
    # Test with sample
    sample_ecg, sample_label = generate_synthetic_ecg_data(1)
    result = predict_afib(sample_ecg[0].flatten(), model)
    print(f"\nSample prediction: {result}")