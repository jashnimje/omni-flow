// Unit tests for the protocol core, built and run natively:
//   c++ -std=c++11 -Wall -Wextra -Werror -o /tmp/core_test host/core_test.cpp omni_core.cpp && /tmp/core_test
// Add -DOMNI_SMALL to run them with the Uno's limits.
#include <stdio.h>
#include <string.h>

#include <string>
#include <vector>

#include "../omni_core.h"

using namespace omni;

static int failures = 0;
#define CHECK(cond)                                              \
  do {                                                           \
    if (!(cond)) {                                               \
      printf("FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond);     \
      failures++;                                                \
    }                                                            \
  } while (0)

class FakeHal : public Hal {
 public:
  int digital[MAX_PINS] = {0};
  int analog[MAX_PINS] = {0};
  int pwm[MAX_PINS] = {0};
  int servo[MAX_PINS] = {0};
  Mode modes[MAX_PINS] = {MODE_NONE};
  std::vector<uint32_t> ir;
  unsigned long now = 1000;
  // Set to act like a board with no free PWM or servo channel.
  bool refuse = false;
  bool setMode(int pin, Mode mode) override {
    if (refuse) return false;
    modes[pin] = mode;
    return true;
  }
  void writeDigital(int pin, int value) override { digital[pin] = value; }
  int readDigital(int pin) override { return digital[pin]; }
  int readAnalogPercent(int pin) override { return analog[pin]; }
  void writePwmPercent(int pin, int percent) override { pwm[pin] = percent; }
  void writeServo(int pin, int degrees) override { servo[pin] = degrees; }
  void sendIr(uint32_t bits) override { ir.push_back(bits); }
  bool hasIr() override { return true; }
  unsigned long millis() override { return now; }
};

class Capture : public Out {
 public:
  std::string text;
  void write(const char* t) override { text += t; }
  std::string take() {
    std::string s = text;
    text.clear();
    return s;
  }
};

static bool has(const std::string& s, const char* part) { return s.find(part) != std::string::npos; }

static std::string run(Core& core, const char* line) {
  Capture out;
  core.handleLine(line, out);
  return out.take();
}

static void testProfiles() {
  // Board profiles keep their reserved pins.
  CHECK(picoWCaps(25) == 0 && picoWCaps(23) == 0 && picoWCaps(29) == 0);
  CHECK(picoWCaps(26) & CAP_ADC);
  CHECK(esp32Caps(6) == 0 && esp32Caps(11) == 0);
  CHECK(esp32Caps(1) == 0 && esp32Caps(3) == 0);  // UART0, the USB serial port
  CHECK(esp32Caps(34) == (CAP_IN | CAP_ADC));
  CHECK(!(esp32Caps(4) & CAP_ADC));  // ADC2: not while Wi-Fi is on
  CHECK(esp8266Caps(17) == CAP_ADC && esp8266Caps(1) == 0 && esp8266Caps(9) == 0);
  CHECK(unoCaps(0) == 0 && unoCaps(1) == 0);
  CHECK((unoCaps(9) & CAP_PWM) && !(unoCaps(8) & CAP_PWM));
  // The Servo library takes Timer1, the PWM timer of 9 and 10.
  CHECK(!(unoCaps(9) & CAP_SERVO) && !(unoCaps(10) & CAP_SERVO) && (unoCaps(8) & CAP_SERVO));

  // Every input has a pull-up except ESP32 34 to 39 and ESP8266 16.
  for (int pin = 0; pin < 40; pin++) {
    uint8_t (*profiles[])(int) = {esp32Caps, esp8266Caps, picoWCaps, unoCaps, hostCaps};
    for (unsigned i = 0; i < sizeof(profiles) / sizeof(profiles[0]); i++) {
      uint8_t caps = profiles[i](pin);
      bool noPullup = (profiles[i] == esp32Caps && pin >= 34) || (profiles[i] == esp8266Caps && pin == 16);
      if (caps & CAP_IN) CHECK(!(caps & CAP_PULLUP) == noPullup);
      if (!(caps & CAP_IN)) CHECK(!(caps & CAP_PULLUP));
    }
  }

  // ESP8266 16 has no pull-up and A0 (17) is analog only.
  FakeHal hal;
  Core core("test_node", "fw", BOARD_ESP8266, hal);
  CHECK(has(run(core, "{\"cmd\":\"pin.mode\",\"pin\":16,\"mode\":\"in_pullup\"}"), "cannot do that mode"));
  CHECK(has(run(core, "{\"cmd\":\"pin.mode\",\"pin\":16,\"mode\":\"in\"}"), "\"event\":\"ack\""));
  CHECK(has(run(core, "{\"cmd\":\"pin.mode\",\"pin\":17,\"mode\":\"in\"}"), "cannot do that mode"));
  CHECK(has(run(core, "{\"cmd\":\"pin.mode\",\"pin\":17,\"mode\":\"adc\"}"), "\"event\":\"ack\""));
  CHECK(has(run(core, "{\"cmd\":\"describe\"}"), "{\"pin\":17,\"caps\":[\"adc\"]}"));
}

static void testParser() {
  Args a;
  CHECK(parseArgs("{\"s\":\"a\\nb\\t\\/\\\"\\\\\"}", a) == 0);
  CHECK(strcmp(a.str("s"), "a\nb\t/\"\\") == 0);
  CHECK(parseArgs("{\"s\":\"\\u0041\"}", a) != 0);
  CHECK(parseArgs("{\"s\":\"\\q\"}", a) != 0);

  // Too long is an error, never a cut value.
  std::string fits(OMNI_TEXT_MAX - 1, 'x');
  std::string over(OMNI_TEXT_MAX, 'x');
  CHECK(parseArgs(("{\"s\":\"" + fits + "\"}").c_str(), a) == 0);
  CHECK(a.str("s") && strlen(a.str("s")) == fits.size());
  const char* error = parseArgs(("{\"s\":\"" + over + "\"}").c_str(), a);
  CHECK(error && strcmp(error, "value too long") == 0);
  error = parseArgs("{\"averyverylongkey\":1}", a);
  CHECK(error && strcmp(error, "value too long") == 0);

  FakeHal hal;
  Core core("test_node", "fw", BOARD_HOST, hal);
  // A line that does not parse still answers with its id.
  std::string r = run(core, "{\"cmd\":\"pin.mode\",\"id\":42,\"a\":[1]}");
  CHECK(has(r, "\"event\":\"error\"") && has(r, "\"id\":42}"));
  r = run(core, ("{\"cmd\":\"node.set\",\"name\":\"" + over + "\",\"id\":43}").c_str());
  CHECK(has(r, "value too long") && has(r, "\"id\":43}"));

  // The pin is a whole number in range; nothing else counts as a pin.
  const char* badPins[] = {"true", "\"4\"", "-1", "20", "40", "99999999999", "null"};
  for (unsigned i = 0; i < sizeof(badPins) / sizeof(badPins[0]); i++) {
    std::string line = std::string("{\"cmd\":\"pin.mode\",\"mode\":\"out\",\"pin\":") + badPins[i] + "}";
    CHECK(has(run(core, line.c_str()), "pin not available"));
  }
  CHECK(has(run(core, "{\"cmd\":\"pin.mode\",\"mode\":\"out\",\"pin\":1}"), "\"event\":\"ack\""));
}

static void testPinModes() {
  FakeHal hal;
  Core core("test_node", "fw", BOARD_HOST, hal);
  Capture out;

  // A watch goes when the pin stops being an input.
  run(core, "{\"cmd\":\"pin.mode\",\"pin\":4,\"mode\":\"in\"}");
  CHECK(has(run(core, "{\"cmd\":\"pin.watch\",\"pin\":4,\"ms\":10}"), "\"event\":\"ack\""));
  run(core, "{\"cmd\":\"pin.mode\",\"pin\":4,\"mode\":\"out\"}");
  run(core, "{\"cmd\":\"pin.write\",\"pin\":4,\"value\":1}");
  hal.now += 100;
  core.poll(out);
  CHECK(out.take().empty());
  // Turning a watch off is taken in any mode.
  CHECK(has(run(core, "{\"cmd\":\"pin.watch\",\"pin\":4,\"off\":true,\"id\":3}"), "\"cmd\":\"pin.watch\",\"pin\":4,\"id\":3"));
  CHECK(has(run(core, "{\"cmd\":\"pin.watch\",\"pin\":4}"), "only input pins"));
  // gpio_write moves a watched input to output too.
  run(core, "{\"cmd\":\"pin.mode\",\"pin\":8,\"mode\":\"in\"}");
  run(core, "{\"cmd\":\"pin.watch\",\"pin\":8,\"ms\":10}");
  run(core, "{\"cmd\":\"gpio_write\",\"pin\":8,\"value\":1}");
  hal.now += 100;
  core.poll(out);
  CHECK(out.take().empty());

  // none releases a pin and its watch.
  run(core, "{\"cmd\":\"pin.mode\",\"pin\":5,\"mode\":\"in_pullup\"}");
  run(core, "{\"cmd\":\"pin.watch\",\"pin\":5,\"ms\":10}");
  CHECK(has(run(core, "{\"cmd\":\"pin.mode\",\"pin\":5,\"mode\":\"none\",\"id\":4}"), "\"cmd\":\"pin.mode\",\"pin\":5,\"id\":4"));
  CHECK(hal.modes[5] == MODE_NONE);
  hal.digital[5] = 1;
  hal.now += 100;
  core.poll(out);
  CHECK(out.take().empty());
  CHECK(has(run(core, "{\"cmd\":\"pin.read\",\"pin\":5}"), "set pin.mode first"));
  CHECK(has(run(core, "{\"cmd\":\"pin.mode\",\"pin\":9,\"mode\":\"none\"}"), "\"event\":\"ack\""));
  CHECK(has(run(core, "{\"cmd\":\"pin.mode\",\"pin\":30,\"mode\":\"none\"}"), "pin not available"));
  CHECK(has(run(core, "{\"cmd\":\"pin.mode\",\"pin\":9,\"mode\":\"fast\"}"), "mode must be none, in"));

  // A servo starts at 90 degrees on every board.
  run(core, "{\"cmd\":\"pin.mode\",\"pin\":7,\"mode\":\"servo\"}");
  CHECK(hal.servo[7] == 90);
  CHECK(has(run(core, "{\"cmd\":\"pin.read\",\"pin\":7}"), "\"value\":90"));

  // A refused PWM or servo attach is an error, and the pin keeps its old mode and level.
  run(core, "{\"cmd\":\"pin.mode\",\"pin\":6,\"mode\":\"out\"}");
  run(core, "{\"cmd\":\"pin.write\",\"pin\":6,\"value\":1}");
  hal.refuse = true;
  hal.digital[6] = 0;
  CHECK(has(run(core, "{\"cmd\":\"pin.mode\",\"pin\":6,\"mode\":\"pwm\",\"id\":5}"), "no free PWM or servo channel\",\"id\":5"));
  hal.refuse = false;
  CHECK(hal.modes[6] == MODE_OUT && hal.digital[6] == 1);
  CHECK(has(run(core, "{\"cmd\":\"pin.read\",\"pin\":6}"), "\"value\":1"));
  CHECK(has(run(core, "{\"cmd\":\"pwm.write\",\"pin\":6,\"value\":5}"), "set pin.mode pwm first"));

  // describe reports the watch limit and the pins that have a mode.
  std::string d = run(core, "{\"cmd\":\"describe\"}");
  char watches[24];
  snprintf(watches, sizeof(watches), "\"watches\":%d", MAX_WATCHES);
  CHECK(has(d, watches));
  CHECK(has(d, "{\"pin\":0,\"caps\":[\"in\",\"pullup\",\"out\",\"pwm\",\"servo\"]}"));
  CHECK(has(d, "\"set\":[{\"pin\":4,\"mode\":\"out\"},{\"pin\":6,\"mode\":\"out\"},{\"pin\":7,\"mode\":\"servo\"},"
               "{\"pin\":8,\"mode\":\"out\"}]"));
}

class FakeSetupHal : public SetupHal {
 public:
  Capture* out = 0;
  int saves = 0;
  int starts = 0;
  int stops = 0;
  bool ackedBeforeStart = false;
  void saveSettings() override { saves++; }
  void startWifi() override {
    starts++;
    ackedBeforeStart = out && has(out->text, "\"event\":\"ack\"");
  }
  void stopWifi() override { stops++; }
  bool wifiConnected() override { return true; }
  void localIp(uint8_t ip[4]) override {
    ip[0] = 192;
    ip[1] = 168;
    ip[2] = 1;
    ip[3] = 9;
  }
  int rssi() override { return -61; }
};

static void testSetup() {
  FakeHal hal;
  Settings settings;
  memset(&settings, 0, sizeof(settings));
  settings.irPin = -1;
  strcpy(settings.node, "fresh");
  Core core(settings.node, "fw", BOARD_HOST, hal);
  FakeSetupHal setupHal;
  Setup setup(core, settings, setupHal, 38950);
  core.setExtension(&setup);
  Capture out;
  setupHal.out = &out;

  // Nothing that changes the setup is taken over the network.
  const char* setupLines[] = {"{\"cmd\":\"wifi.set\",\"ssid\":\"net\",\"password\":\"longenough\"}",
                              "{\"cmd\":\"wifi.clear\"}", "{\"cmd\":\"node.set\",\"name\":\"evil\"}",
                              "{\"cmd\":\"ir.pin\",\"pin\":3}"};
  for (unsigned i = 0; i < sizeof(setupLines) / sizeof(setupLines[0]); i++) {
    CHECK(has(run(core, setupLines[i]), "setup commands are only taken over USB"));
  }
  CHECK(setupHal.saves == 0 && strcmp(settings.node, "fresh") == 0);
  CHECK(has(run(core, "{\"cmd\":\"wifi.status\"}"), "\"configured\":false"));

  setup.fromSerial = true;
  CHECK(has(run(core, "{\"cmd\":\"wifi.set\",\"ssid\":\"\"}"), "ssid is 1 to 32"));
  if (OMNI_TEXT_MAX > 33) {
    CHECK(has(run(core, "{\"cmd\":\"wifi.set\",\"ssid\":\"123456789012345678901234567890123\"}"), "ssid is 1 to 32"));
  }
  CHECK(has(run(core, "{\"cmd\":\"wifi.set\",\"ssid\":\"net\",\"password\":\"seven77\"}"), "password is empty, 8 to 63"));
  if (OMNI_TEXT_MAX > 64) {
    std::string notHex(64, 'g');
    std::string hex(64, 'a');
    CHECK(has(run(core, ("{\"cmd\":\"wifi.set\",\"ssid\":\"net\",\"password\":\"" + notHex + "\"}").c_str()),
              "password is empty, 8 to 63"));
    CHECK(has(run(core, ("{\"cmd\":\"wifi.set\",\"ssid\":\"net\",\"password\":\"" + hex + "\"}").c_str()),
              "\"cmd\":\"wifi.set\""));
  }
  CHECK(setupHal.starts == (OMNI_TEXT_MAX > 64 ? 1 : 0));
  // The ack goes out before the board starts joining, which can block.
  core.handleLine("{\"cmd\":\"wifi.set\",\"ssid\":\"net\",\"password\":\"longenough\",\"id\":8}", out);
  CHECK(has(out.take(), "\"cmd\":\"wifi.set\",\"id\":8"));
  CHECK(setupHal.ackedBeforeStart);
  CHECK(strcmp(settings.ssid, "net") == 0 && strcmp(settings.password, "longenough") == 0);
  CHECK(has(run(core, "{\"cmd\":\"wifi.status\",\"id\":9}"),
            "{\"node\":\"fresh\",\"event\":\"wifi\",\"configured\":true,\"connected\":true,"
            "\"ip\":\"192.168.1.9\",\"port\":38950,\"rssi\":-61,\"id\":9}"));
  int stops = setupHal.stops;
  CHECK(has(run(core, "{\"cmd\":\"wifi.clear\"}"), "\"cmd\":\"wifi.clear\""));
  CHECK(setupHal.stops == stops + 1 && settings.ssid[0] == 0 && settings.password[0] == 0);
  CHECK(has(run(core, "{\"cmd\":\"wifi.status\"}"), "\"configured\":false"));

  // Names never need escaping in JSON.
  const char* badNames[] = {"", "Desk", "9desk", "_desk", "desk board", "desk\\\"x", "desk\\\\x", "abcdefghijklmnopqrstuvwx"};
  for (unsigned i = 0; i < sizeof(badNames) / sizeof(badNames[0]); i++) {
    std::string line = std::string("{\"cmd\":\"node.set\",\"name\":\"") + badNames[i] + "\"}";
    CHECK(has(run(core, line.c_str()), "\"event\":\"error\""));
  }
  CHECK(has(run(core, "{\"cmd\":\"node.set\",\"name\":\"Desk\"}"), "name is lower case letters, digits, _ and -"));
  CHECK(strcmp(core.node(), "fresh") == 0);
  CHECK(has(run(core, "{\"cmd\":\"node.set\",\"name\":\"abcdefghijklmnopqrstuvw\"}"), "\"event\":\"ack\""));
  CHECK(has(run(core, "{\"cmd\":\"node.set\",\"name\":\"desk_board-2\"}"), "{\"node\":\"desk_board-2\",\"event\":\"ack\""));
  CHECK(strcmp(settings.node, "desk_board-2") == 0);

  // A stored name that is not valid is dropped, so the board makes a new one.
  Settings stored;
  memset(&stored, 'x', sizeof(stored));
  sanitizeSettings(stored);
  CHECK(strlen(stored.node) == sizeof(stored.node) - 1);
  strcpy(stored.node, "Bad\"Name");
  sanitizeSettings(stored);
  CHECK(stored.node[0] == 0);
  strcpy(stored.node, "good_name");
  sanitizeSettings(stored);
  CHECK(strcmp(stored.node, "good_name") == 0);

  // The IR pin is kept from pin commands, and only a free output pin can be it.
  run(core, "{\"cmd\":\"pin.mode\",\"pin\":6,\"mode\":\"out\"}");
  CHECK(has(run(core, "{\"cmd\":\"ir.pin\",\"pin\":6}"), "set pin.mode none first"));
  CHECK(has(run(core, "{\"cmd\":\"ir.pin\",\"pin\":16}"), "pin must be an output pin"));
  CHECK(has(run(core, "{\"cmd\":\"ir.pin\",\"pin\":true}"), "pin must be an output pin"));
  CHECK(has(run(core, "{\"cmd\":\"ir.pin\",\"pin\":3}"), "\"cmd\":\"ir.pin\",\"pin\":3"));
  CHECK(settings.irPin == 3);
  CHECK(has(run(core, "{\"cmd\":\"pin.mode\",\"pin\":3,\"mode\":\"in\"}"), "pin not available"));
  CHECK(has(run(core, "{\"cmd\":\"gpio_write\",\"pin\":3,\"value\":1}"), "pin not allowed"));
  CHECK(!has(run(core, "{\"cmd\":\"describe\"}"), "{\"pin\":3,"));
  CHECK(has(run(core, "{\"cmd\":\"ir.pin\",\"pin\":-1}"), "\"cmd\":\"ir.pin\""));
  CHECK(settings.irPin == -1);
  CHECK(has(run(core, "{\"cmd\":\"pin.mode\",\"pin\":3,\"mode\":\"in\"}"), "\"event\":\"ack\""));
}

#ifndef OMNI_SMALL
// The full v2 walk-through on a Pico W profile, whose pins go past the Uno's 20.
static void testPicoCore() {
  FakeHal hal;
  Core core("test_node", "omniflow-node/2 test", BOARD_PICO_W, hal);
  Capture out;

  core.handleLine("{\"cmd\":\"describe\",\"id\":1}", out);
  std::string d = out.take();
  CHECK(has(d, "\"event\":\"describe\""));
  CHECK(has(d, "\"proto\":2"));
  CHECK(has(d, "\"board\":\"pico_w\""));
  CHECK(has(d, "{\"pin\":26,\"caps\":[\"in\",\"pullup\",\"out\",\"pwm\",\"servo\",\"adc\"]}"));
  CHECK(!has(d, "{\"pin\":25,"));
  CHECK(has(d, "\"set\":[]"));
  CHECK(has(d, "\"id\":1}"));

  // Writing before choosing a mode is refused; a radio pin is refused outright.
  core.handleLine("{\"cmd\":\"pin.write\",\"pin\":16,\"value\":1,\"id\":2}", out);
  CHECK(has(out.take(), "set pin.mode out first"));
  core.handleLine("{\"cmd\":\"pin.mode\",\"pin\":25,\"mode\":\"out\",\"id\":3}", out);
  CHECK(has(out.take(), "pin not available"));
  core.handleLine("{\"cmd\":\"pin.mode\",\"pin\":16,\"mode\":\"adc\",\"id\":4}", out);
  CHECK(has(out.take(), "cannot do that mode"));

  core.handleLine("{\"cmd\":\"pin.mode\",\"pin\":16,\"mode\":\"out\",\"id\":5}", out);
  CHECK(has(out.take(), "\"cmd\":\"pin.mode\",\"pin\":16,\"id\":5"));
  CHECK(hal.modes[16] == MODE_OUT);
  core.handleLine("{\"cmd\":\"pin.write\",\"pin\":16,\"value\":true,\"id\":6}", out);
  CHECK(has(out.take(), "\"value\":1,\"id\":6"));
  CHECK(hal.digital[16] == 1);
  core.handleLine("{\"cmd\":\"pin.read\",\"pin\":16,\"id\":7}", out);
  CHECK(has(out.take(), "\"value\":1"));
  // Re-sending the same mode keeps the output as it is.
  core.handleLine("{\"cmd\":\"pin.mode\",\"pin\":16,\"mode\":\"out\"}", out);
  CHECK(has(out.take(), "\"event\":\"ack\""));
  CHECK(hal.digital[16] == 1);
  core.handleLine("{\"cmd\":\"pin.read\",\"pin\":16}", out);
  CHECK(has(out.take(), "\"value\":1"));

  core.handleLine("{\"cmd\":\"pin.mode\",\"pin\":15,\"mode\":\"pwm\"}", out);
  out.take();
  core.handleLine("{\"cmd\":\"pwm.write\",\"pin\":15,\"value\":150}", out);
  CHECK(has(out.take(), "0 to 100"));
  core.handleLine("{\"cmd\":\"pwm.write\",\"pin\":15,\"value\":40}", out);
  out.take();
  CHECK(hal.pwm[15] == 40);

  core.handleLine("{\"cmd\":\"pin.mode\",\"pin\":13,\"mode\":\"servo\"}", out);
  core.handleLine("{\"cmd\":\"servo.write\",\"pin\":13,\"value\":90.6}", out);
  out.take();
  CHECK(hal.servo[13] == 90);

  // Watching an input reports changes after the interval, and only real ones.
  core.handleLine("{\"cmd\":\"pin.mode\",\"pin\":14,\"mode\":\"in_pullup\"}", out);
  hal.digital[14] = 1;
  core.handleLine("{\"cmd\":\"pin.watch\",\"pin\":14,\"ms\":50,\"id\":9}", out);
  CHECK(has(out.take(), "\"value\":1,\"id\":9"));
  hal.digital[14] = 0;
  hal.now += 20;
  core.poll(out);
  CHECK(out.take().empty());
  hal.now += 40;
  core.poll(out);
  CHECK(has(out.take(), "{\"node\":\"test_node\",\"event\":\"pin.changed\",\"pin\":14,\"value\":0}"));
  hal.now += 60;
  core.poll(out);
  CHECK(out.take().empty());

  // An analog watch with a delta ignores small drift.
  core.handleLine("{\"cmd\":\"pin.mode\",\"pin\":26,\"mode\":\"adc\"}", out);
  hal.analog[26] = 50;
  core.handleLine("{\"cmd\":\"pin.watch\",\"pin\":26,\"ms\":100,\"delta\":3}", out);
  out.take();
  hal.analog[26] = 52;
  hal.now += 100;
  core.poll(out);
  CHECK(out.take().empty());
  hal.analog[26] = 60;
  hal.now += 100;
  core.poll(out);
  CHECK(has(out.take(), "\"pin\":26,\"value\":60"));
  core.handleLine("{\"cmd\":\"pin.watch\",\"pin\":26,\"off\":true}", out);
  out.take();
  hal.analog[26] = 90;
  hal.now += 100;
  core.poll(out);
  CHECK(out.take().empty());

  // Watching an output is refused.
  core.handleLine("{\"cmd\":\"pin.watch\",\"pin\":16}", out);
  CHECK(has(out.take(), "only input pins"));

  // IR both ways, and the v1 names.
  core.handleLine("{\"cmd\":\"ir.send\",\"address\":4,\"command\":8,\"id\":10}", out);
  CHECK(has(out.take(), "\"cmd\":\"ir.send\",\"id\":10"));
  core.handleLine("{\"cmd\":\"ir_send\",\"protocol\":\"NEC\",\"hex\":\"0x20DF10EF\"}", out);
  out.take();
  CHECK(hal.ir.size() == 2 && hal.ir[0] == hal.ir[1]);
  core.handleLine("{\"cmd\":\"ir.send\",\"protocol\":\"RC5\",\"hex\":\"0x1\"}", out);
  CHECK(has(out.take(), "only NEC"));
  core.handleLine("{\"cmd\":\"gpio_write\",\"pin\":17,\"value\":1}", out);
  CHECK(has(out.take(), "\"cmd\":\"pin.write\",\"pin\":17,\"value\":1"));
  core.handleLine("{\"cmd\":\"gpio_write\",\"pin\":25,\"value\":1}", out);
  CHECK(has(out.take(), "pin not allowed"));

  hal.now = 125000;
  core.hello(out, 38950);
  CHECK(out.take() ==
        "{\"node\":\"test_node\",\"event\":\"hello\",\"proto\":2,\"board\":\"pico_w\",\"port\":38950,\"up\":125,\"set\":6}\n");

  // ESP32 34 to 39 have no pull-up.
  Core esp32("test_node", "fw", BOARD_ESP32, hal);
  CHECK(has(run(esp32, "{\"cmd\":\"pin.mode\",\"pin\":34,\"mode\":\"in_pullup\"}"), "cannot do that mode"));
  CHECK(has(run(esp32, "{\"cmd\":\"pin.mode\",\"pin\":34,\"mode\":\"in\"}"), "\"event\":\"ack\""));
  CHECK(has(run(esp32, "{\"cmd\":\"pin.mode\",\"pin\":1,\"mode\":\"out\"}"), "pin not available"));
}

// A reply goes out as one datagram from udpLine in omniflow_node.ino, so
// describe has to fit it with every pin set and the longest name.
static void testDescribeFits() {
  const BoardProfile* boards[] = {&BOARD_ESP32, &BOARD_ESP8266, &BOARD_PICO_W, &BOARD_UNO};
  for (unsigned b = 0; b < sizeof(boards) / sizeof(boards[0]); b++) {
    FakeHal hal;
    Core core("abcdefghijklmnopqrstuvw", "omniflow-node/2 esp8266", *boards[b], hal);
    for (int pin = 0; pin < MAX_PINS; pin++) {
      uint8_t caps = boards[b]->caps(pin);
      const char* mode = (caps & CAP_PULLUP) ? "in_pullup" : (caps & CAP_SERVO) ? "servo" : (caps & CAP_ADC) ? "adc" : "in";
      if (!caps) continue;
      char line[80];
      snprintf(line, sizeof(line), "{\"cmd\":\"pin.mode\",\"pin\":%d,\"mode\":\"%s\"}", pin, mode);
      CHECK(has(run(core, line), "\"event\":\"ack\""));
    }
    std::string d = run(core, "{\"cmd\":\"describe\",\"id\":2147483647}");
    if (d.size() > 3072) printf("describe for %s is %u bytes\n", boards[b]->name, (unsigned)d.size());
    CHECK(d.size() <= 3072);
  }
}
#endif

int main() {
  // NEC: LG power, the classic MSB-first 0x20DF10EF, is address 4, command 8.
  CHECK(necFrame(4, 8) == necFromMsbCode(0x20DF10EF));
  CHECK(necFrame(4, 8) == (0x04u | (0xFBu << 8) | (0x08u << 16) | (0xF7u << 24)));
  CHECK(necFrame(0x1234, 0x56) == (0x34u | (0x12u << 8) | (0x56u << 16) | (0xA9u << 24)));

  testProfiles();
  testParser();
  testPinModes();
  testSetup();
#ifndef OMNI_SMALL
  testPicoCore();
  testDescribeFits();
#endif

  // Bad input never crashes and always answers.
  FakeHal hal;
  Core core("test_node", "fw", BOARD_HOST, hal);
  const char* junk[] = {"", "not json", "{", "{\"cmd\":}", "{\"cmd\":\"x\",\"a\":{\"b\":1}}", "[1,2]",
                        "{\"cmd\":\"teleport\"}", "{\"id\":3}"};
  for (unsigned i = 0; i < sizeof(junk) / sizeof(junk[0]); i++) {
    CHECK(has(run(core, junk[i]), "\"event\":\"error\""));
  }

  if (failures) {
    printf("%d check(s) failed\n", failures);
    return 1;
  }
  printf("all core checks passed\n");
  return 0;
}
