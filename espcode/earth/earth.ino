#include <WiFi.h>
#include <WiFiManager.h>
#include <Firebase_ESP_Client.h>
#include <addons/RTDBHelper.h>
#include <Wire.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include <LiquidCrystal_I2C.h>

// ================== CONFIG ==================
#define API_KEY "AIzaSyCO1I_8iOYD8820Drj31Ks3trnUTEQ3S43k"
#define DATABASE_URL "https://earthquakealert-8923c-default-rtdb.asia-southeast1.firebasedatabase.app"
#define AUTH_TOKEN "8Q0LhtF8CY2TPHbHyZnyLQ5qD31HXxwlCcjpxAyE"

#define MP3_RX 16
#define MP3_TX 17

Adafruit_MPU6050 mpu;
LiquidCrystal_I2C lcd(0x27, 16, 2);
FirebaseData fbdo;
FirebaseAuth auth;
FirebaseConfig config;

// === PHIVOLCS-STYLE PGA TRACKING ===
float baselineZ_g = 1.0;           // Calibrated gravity (≈1.0g)
float maxPgaInWindow = 0.0;        // Peak PGA in current 10-second window
float currentPga = 0.0;            // Instantaneous for LCD
unsigned long lastSend = 0;
unsigned long lastSample = 0;
const unsigned long sampleInterval = 20;    // 50 Hz (1000/20)
const unsigned long sendInterval = 10000;   // 10 seconds → PHIVOLCS standard

void setup() {
  Serial.begin(115200);
  Serial2.begin(9600, SERIAL_8N1, MP3_RX, MP3_TX);

  lcd.init();
  lcd.backlight();
  lcd.setCursor(0,0); lcd.print("GeoAlert v2");
  lcd.setCursor(0,1); lcd.print("Booting...");

  // WiFi Manager
  WiFiManager wm;
  wm.setConfigPortalTimeout(180);
  if (!wm.autoConnect("GeoAlert-ESP32", "12345678")) {
    lcd.clear(); lcd.print("WiFi Failed");
    delay(3000); ESP.restart();
  }

  lcd.clear(); lcd.print("WiFi OK");
  lcd.setCursor(0,1); lcd.print(WiFi.localIP());
  delay(2000);

  // Firebase
  config.api_key = API_KEY;
  config.database_url = DATABASE_URL;
  config.signer.tokens.legacy_token = AUTH_TOKEN;
  Firebase.begin(&config, &auth);
  Firebase.reconnectWiFi(true);

  // MPU6050 Setup
  if (!mpu.begin()) {
    lcd.clear(); lcd.print("MPU6050 ERROR");
    while (1) delay(10);
  }
  mpu.setAccelerometerRange(MPU6050_RANGE_8_G);
  mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);  // Good for seismic

  // === GRAVITY CALIBRATION (PHIVOLCS-style) ===
  lcd.clear(); lcd.print("Calibrating...");
  lcd.setCursor(0,1); lcd.print("Keep flat!");
  delay(2000);

  float sumZ = 0.0;
  for (int i = 0; i < 300; i++) {
    sensors_event_t a, g, temp;
    mpu.getEvent(&a, &g, &temp);
    sumZ += a.acceleration.z / 9.81;
    delay(10);
  }
  baselineZ_g = sumZ / 300.0;
  Serial.printf("Baseline Z = %.4f g\n", baselineZ_g);

  lcd.clear(); lcd.print("PHIVOLCS Mode");
  lcd.setCursor(0,1); lcd.print("Ready!");
  delay(1500);

  lastSample = millis();
  lastSend = millis();
}

void loop() {
  unsigned long now = millis();

  // === HIGH-FREQUENCY SAMPLING (50 Hz) ===
  if (now - lastSample >= sampleInterval) {
    lastSample = now;

    sensors_event_t a, g, temp;
    mpu.getEvent(&a, &g, &temp);

    // Convert to g
    float ax = a.acceleration.x / 9.81;
    float ay = a.acceleration.y / 9.81;
    float az = a.acceleration.z / 9.81;

    // 3D vector magnitude
    float vector = sqrt(ax*ax + ay*ay + az*az);

    // True dynamic acceleration (remove gravity)
    currentPga = fabs(vector - baselineZ_g);  // Use fabs() → standard

    // Track maximum in current 10-second window
    if (currentPga > maxPgaInWindow) {
      maxPgaInWindow = currentPga;
    }

    // Real-time LCD update
    String intensity = getIntensity(currentPga);
    updateLCD(intensity, currentPga);
    playAlarm(currentPga);
  }

  // === SEND MAX PGA EVERY 10 SECONDS (PHIVOLCS EXACT) ===
  if (now - lastSend >= sendInterval) {
    sendData(maxPgaInWindow > 0.001 ? maxPgaInWindow : 0.0);  // Avoid sending tiny noise
    maxPgaInWindow = 0.0;  // Reset for next window
    lastSend = now;
  }
}

// === SEND TO FIREBASE (PHIVOLCS-STYLE DATA) ===
void sendData(float pga) {
  String intensity = getIntensity(pga);

  String path = "/sensor/history/" + String(millis());
  FirebaseJson json;
  json.set("pga", pga);
  json.set("intensity", intensity);
  json.set("timestamp", millis());

  if (Firebase.RTDB.setJSON(&fbdo, path.c_str(), &json)) {
    Serial.printf("Sent → PGA: %.4f g | PEIS: %s\n", pga, intensity.c_str());
  } else {
    Serial.println("Failed: " + fbdo.errorReason());
  }
}

// === PHIVOLCS PEIS SCALE (Official Thresholds) ===
String getIntensity(float pga) {
  if (pga < 0.0017) return "I";
  if (pga < 0.014)  return "II";
  if (pga < 0.039)  return "III";
  if (pga < 0.092)  return "IV";
  if (pga < 0.18)   return "V";
  if (pga < 0.34)   return "VI";
  if (pga < 0.65)   return "VII";
  if (pga < 1.24)   return "VIII";
  if (pga < 2.5)    return "IX";
  return "X";
}

void updateLCD(String intensity, float pga) {
  lcd.clear();
  lcd.setCursor(0,0); 
  lcd.print("PEIS: "); lcd.print(intensity);
  lcd.setCursor(0,1); 
  lcd.print("PGA:"); lcd.print(pga, 4); lcd.print("g ");
}

void playAlarm(float pga) {
  if (pga >= 0.65)       Serial2.println("AT+PLAY=3");  // Destructive
  else if (pga >= 0.34)  Serial2.println("AT+PLAY=2");  // Very Strong
  else if (pga >= 0.18)  Serial2.println("AT+PLAY=1");  // Strong
  else                   Serial2.println("AT+PLAY=0");  // Stop
}