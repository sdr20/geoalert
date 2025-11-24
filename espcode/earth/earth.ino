#include <WiFi.h>
#include <WiFiManager.h>
#include <Firebase_ESP_Client.h>
#include <addons/RTDBHelper.h>
#include <Wire.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>
#include <LiquidCrystal_I2C.h>          // Use "LiquidCrystal I2C by Frank de Brabander" (ESP32 compatible)

// ================== YOUR CONFIG ==================
#define API_KEY "AIzaSyCO1I_8iOYD8820Drj31Ks3trnUTEQ3S43k"
#define DATABASE_URL "https://earthquakealert-8923c-default-rtdb.asia-southeast1.firebasedatabase.app"
#define AUTH_TOKEN "8Q0LhtF8CY2TPHbHyZnyLQ5qD31HXxwlCcjpxAyE"

// ================== PINS ==================
#define MP3_RX 16
#define MP3_TX 17

Adafruit_MPU6050 mpu;
LiquidCrystal_I2C lcd(0x27, 16, 2);   // Try 0x3F if screen blank
FirebaseData fbdo;
FirebaseAuth auth;
FirebaseConfig config;

unsigned long lastSend = 0;
const long interval = 10000;          // 10 seconds (PHIVOLCS standard)
float baselineZ_g = 1.0;              // Will be calibrated in g (≈1.0)

void setup() {
  Serial.begin(115200);
  Serial2.begin(9600, SERIAL_8N1, MP3_RX, MP3_TX);

  lcd.init();
  lcd.backlight();
  lcd.setCursor(0,0); lcd.print("GeoAlert");
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

  // MPU6050
  if (!mpu.begin()) {
    lcd.clear(); lcd.print("MPU6050 ERROR");
    while (1) delay(10);
  }
  mpu.setAccelerometerRange(MPU6050_RANGE_8_G);
  mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);

  // === GRAVITY CALIBRATION (in g) ===
  lcd.clear(); lcd.print("Calibrating...");
  lcd.setCursor(0,1); lcd.print("Keep flat!");

  float sumZ = 0.0;
  for (int i = 0; i < 300; i++) {
    sensors_event_t a, g, temp;
    mpu.getEvent(&a, &g, &temp);
    sumZ += a.acceleration.z / 9.81;   // Convert to g
    delay(10);
  }
  baselineZ_g = sumZ / 300.0;

  Serial.printf("Baseline Z = %.4f g\n", baselineZ_g);
  lcd.clear(); lcd.print("Ready! PGA OK");
  delay(1500);
}

void loop() {
  if (millis() - lastSend >= interval) {
    lastSend = millis();
    sendData();
  }
}

void sendData() {
  sensors_event_t a, g, temp;
  mpu.getEvent(&a, &g, &temp);

  // Convert to real g units
  float ax = a.acceleration.x / 9.81;
  float ay = a.acceleration.y / 9.81;
  float az = a.acceleration.z / 9.81;

  float vector = sqrt(ax*ax + ay*ay + az*az);

  // TRUE PGA in g (gravity removed)
  float pga = vector - baselineZ_g;           // baselineZ_g ≈ 1.0
  if (pga < 0) pga = 0;                       // ← Fixes the "max" error

  String intensity = getIntensity(pga);
  updateLCD(intensity, pga);
  playAlarm(pga);

  // Send to Firebase
  String path = "/sensor/history/" + String(millis());

  FirebaseJson json;
  json.set("x", ax);
  json.set("y", ay);
  json.set("z", az);
  json.set("pga", pga);           // ← TRUE PGA (0.00 when still)
  json.set("intensity", intensity);
  json.set("timestamp", millis());

  if (Firebase.RTDB.setJSON(&fbdo, path.c_str(), &json)) {
    Serial.println("Data sent!");
  } else {
    Serial.println("Failed: " + fbdo.errorReason());
  }

  Serial.printf("PGA: %.4f g → %s\n", pga, intensity.c_str());
}

// === PHIVOLCS PEIS (Official) ===
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
  lcd.setCursor(0,0); lcd.print("PEIS: "); lcd.print(intensity);
  lcd.setCursor(0,1); lcd.print("PGA:"); lcd.print(pga,4); lcd.print("g");
}

void playAlarm(float pga) {
  if (pga >= 0.65)      Serial2.println("AT+PLAY=3");  // Siren
  else if (pga >= 0.34) Serial2.println("AT+PLAY=2");  // Malakas na lindol!
  else if (pga >= 0.18) Serial2.println("AT+PLAY=1");  // Lindol na!
  else                  Serial2.println("AT+PLAY=0");  // Stop
}