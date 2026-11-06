// OmniFlow node firmware for Arduino (Uno, Nano, Mega, ESP32).
// Speaks the OmniFlow MCU protocol (NDJSON v1, docs/DESIGN.md) over USB serial
// at 115200 baud: a button on pin 2, a relay on pin 4, an analog input on A0.

#include <Arduino.h>

const char* NODE_ID = "arduino_node";
const char* FIRMWARE = "omniflow-arduino/1";
const int BUTTON_PIN = 2;
const int RELAY_PIN = 4;
const int ANALOG_PIN = A0;
const unsigned int MAX_LINE = 128;

int lastButtonState = HIGH;
int lastPct = -1;
char line[MAX_LINE + 1];
unsigned int lineLength = 0;
bool lineOverflowed = false;

void beginEvent(const char* event) {
  Serial.print("{\"node\":\"");
  Serial.print(NODE_ID);
  Serial.print("\",\"event\":\"");
  Serial.print(event);
  Serial.print("\"");
}

void endEvent(long id) {
  if (id >= 0) {
    Serial.print(",\"id\":");
    Serial.print(id);
  }
  Serial.println("}");
}

void emitInt(const char* event, const char* key, int value, long id) {
  beginEvent(event);
  Serial.print(",\"");
  Serial.print(key);
  Serial.print("\":");
  Serial.print(value);
  endEvent(id);
}

void emitError(const char* message, long id) {
  beginEvent("error");
  Serial.print(",\"message\":\"");
  Serial.print(message);
  Serial.print("\"");
  endEvent(id);
}

// Reads a non-negative integer "id" from the command line, or -1 when absent.
long readId(const char* text) {
  const char* at = strstr(text, "\"id\":");
  if (at == NULL) return -1;
  at += 5;
  while (*at == ' ') at++;
  if (*at < '0' || *at > '9') return -1;
  return atol(at);
}

bool hasCommand(const char* text, const char* name) {
  char needle[32];
  snprintf(needle, sizeof(needle), "\"cmd\":\"%s\"", name);
  return strstr(text, needle) != NULL;
}

void handleLine(const char* text) {
  long id = readId(text);
  if (hasCommand(text, "describe")) {
    beginEvent("describe");
    Serial.print(",\"fw\":\"");
    Serial.print(FIRMWARE);
    Serial.print("\",\"capabilities\":[\"button\",\"relay\",\"analog_in\"]");
    Serial.print(",\"commands\":[\"describe\",\"relay_on\",\"relay_off\"]");
    endEvent(id);
  } else if (hasCommand(text, "relay_on")) {
    digitalWrite(RELAY_PIN, HIGH);
    emitInt("ack", "relay", 1, id);
  } else if (hasCommand(text, "relay_off")) {
    digitalWrite(RELAY_PIN, LOW);
    emitInt("ack", "relay", 0, id);
  } else {
    emitError("unknown command", id);
  }
}

void setup() {
  Serial.begin(115200);
  pinMode(BUTTON_PIN, INPUT_PULLUP);
  pinMode(RELAY_PIN, OUTPUT);
  digitalWrite(RELAY_PIN, LOW);
  beginEvent("boot");
  Serial.print(",\"fw\":\"");
  Serial.print(FIRMWARE);
  Serial.print("\"");
  endEvent(-1);
}

void loop() {
  int button = digitalRead(BUTTON_PIN);
  if (button == LOW && lastButtonState == HIGH) {
    emitInt("button_press", "pin", BUTTON_PIN, -1);
    delay(40);
  }
  lastButtonState = button;

  int pct = map(analogRead(ANALOG_PIN), 0, 1023, 0, 100);
  if (abs(pct - lastPct) >= 3) {
    lastPct = pct;
    emitInt("analog_change", "value", pct, -1);
  }

  while (Serial.available() > 0) {
    char c = (char)Serial.read();
    if (c == '\n') {
      line[lineLength] = '\0';
      if (lineOverflowed) {
        emitError("line too long", -1);
      } else if (lineLength > 0) {
        handleLine(line);
      }
      lineLength = 0;
      lineOverflowed = false;
    } else if (c != '\r') {
      if (lineLength < MAX_LINE) {
        line[lineLength++] = c;
      } else {
        lineOverflowed = true;
      }
    }
  }

  delay(20);
}
