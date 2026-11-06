// OmniFlow Arduino USB Serial (115200 baud NDJSON) & GPIO / 433MHz RF Bridge
// Compatible with Arduino Uno, Nano, Mega, and ESP32

#include <Arduino.h>

const char* NODE_ID = "arduino_serial_bridge_01";
const int BUTTON_PIN = 2;
const int RELAY_PIN = 4;
const int ANALOG_PIN = A0;

int lastButtonState = HIGH;
int lastKnobPct = -1;
String inputBuffer = "";

void emitEvent(const char* eventName, const char* key, int value) {
  Serial.print("{\"node\":\"");
  Serial.print(NODE_ID);
  Serial.print("\",\"event\":\"");
  Serial.print(eventName);
  Serial.print("\",\"");
  Serial.print(key);
  Serial.print("\":");
  Serial.print(value);
  Serial.println("}");
}

void setup() {
  Serial.begin(115200);
  pinMode(BUTTON_PIN, INPUT_PULLUP);
  pinMode(RELAY_PIN, OUTPUT);
  digitalWrite(RELAY_PIN, LOW);

  Serial.println("{\"node\":\"arduino_serial_bridge_01\",\"event\":\"boot\",\"status\":\"ready\"}");
}

void loop() {
  // 1. Digital Button Trigger
  int btn = digitalRead(BUTTON_PIN);
  if (btn == LOW && lastButtonState == HIGH) {
    emitEvent("button_press", "pin", BUTTON_PIN);
    delay(40);
  }
  lastButtonState = btn;

  // 2. Analog Potentiometer / LDR Sensor (0..1023 -> 0..100%)
  int rawAdc = analogRead(ANALOG_PIN);
  int pct = map(rawAdc, 0, 1023, 0, 100);
  if (abs(pct - lastKnobPct) >= 3) {
    lastKnobPct = pct;
    emitEvent("analog_change", "value", pct);
  }

  // 3. Parse incoming NDJSON commands from OmniFlow Hub
  while (Serial.available() > 0) {
    char c = (char)Serial.read();
    if (c == '\n') {
      inputBuffer.trim();
      if (inputBuffer.indexOf("\"cmd\":\"relay_on\"") >= 0) {
        digitalWrite(RELAY_PIN, HIGH);
        emitEvent("ack", "relay", 1);
      } else if (inputBuffer.indexOf("\"cmd\":\"relay_off\"") >= 0) {
        digitalWrite(RELAY_PIN, LOW);
        emitEvent("ack", "relay", 0);
      }
      inputBuffer = "";
    } else if (c != '\r') {
      inputBuffer += c;
    }
  }

  delay(20);
}

