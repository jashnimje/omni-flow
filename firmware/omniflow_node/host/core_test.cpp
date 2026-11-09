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
  struct RfSend {
    RfProtocol protocol;
    uint32_t code;
    uint8_t bits, repeat;
  };
  std::vector<RfSend> rf;
  // Every level each output pin was driven at, in order, from the moment it
  // became an output.
  std::vector<int> levels[MAX_PINS];
  unsigned long now = 1000;
  // Set to act like a board with no free PWM or servo channel.
  bool refuse = false;
  bool setMode(int pin, Mode mode, int level) override {
    if (refuse) return false;
    modes[pin] = mode;
    if (mode == MODE_OUT) {
      digital[pin] = level;
      levels[pin].push_back(level);
    }
    return true;
  }
  void writeDigital(int pin, int value) override {
    digital[pin] = value;
    levels[pin].push_back(value);
  }
  int readDigital(int pin) override { return digital[pin]; }
  int readAnalogPercent(int pin) override { return analog[pin]; }
  void writePwmPercent(int pin, int percent) override { pwm[pin] = percent; }
  void writeServo(int pin, int degrees) override { servo[pin] = degrees; }
  void sendIr(uint32_t bits) override { ir.push_back(bits); }
  bool hasIr() override { return true; }
  void sendRf(const RfProtocol& protocol, uint32_t code, uint8_t bits, uint8_t repeat) override {
    rf.push_back({protocol, code, bits, repeat});
  }
  bool hasRf() override { return rfPresent; }
  bool rfPresent = true;
  // The reader the core started last, and what each read returns: busyReads
  // reads still going, then the tag in nfcUid (none when empty).
  int nfcType = -1, nfcSs = -2, nfcRst = -2, nfcStarts = 0, nfcReads = 0, busyReads = 0;
  std::vector<uint8_t> nfcUid;
  void startNfc(uint8_t type, int ss, int rst) override {
    nfcType = type;
    nfcSs = ss;
    nfcRst = rst;
    nfcStarts++;
  }
  int pollNfc(uint8_t* uid) override {
    nfcReads++;
    if (busyReads) {
      busyReads--;
      return -1;
    }
    for (size_t i = 0; i < nfcUid.size(); i++) uid[i] = nfcUid[i];
    return (int)nfcUid.size();
  }
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
  int renames = 0;
  bool ackedBeforeStart = false;
  void saveSettings() override { saves++; }
  void nodeRenamed() override { renames++; }
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
  settings.periph.irPin = -1;
  settings.periph.rfPin = -1;
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
                              "{\"cmd\":\"ir.pin\",\"pin\":3}", "{\"cmd\":\"rf.pin\",\"pin\":3}"};
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
  sanitizeSettings(stored, BOARD_HOST);
  CHECK(strlen(stored.node) == sizeof(stored.node) - 1);
  CHECK(stored.periph.irPin == -1 && stored.periph.rfPin == -1);  // 'x' is pin 120
  strcpy(stored.node, "Bad\"Name");
  sanitizeSettings(stored, BOARD_HOST);
  CHECK(stored.node[0] == 0);
  strcpy(stored.node, "good_name");
  sanitizeSettings(stored, BOARD_HOST);
  CHECK(strcmp(stored.node, "good_name") == 0);
  // Stored IR and RF pins must be outputs, and not the same pin.
  stored.periph.irPin = 4;
  stored.periph.rfPin = 4;
  sanitizeSettings(stored, BOARD_HOST);
  CHECK(stored.periph.irPin == 4 && stored.periph.rfPin == -1);
  stored.periph.irPin = 16;  // input only on the host profile
  stored.periph.rfPin = 5;
  sanitizeSettings(stored, BOARD_HOST);
  CHECK(stored.periph.irPin == -1 && stored.periph.rfPin == 5);
  stored.periph.rfPin = 1;  // the Uno's serial port
  sanitizeSettings(stored, BOARD_UNO);
  CHECK(stored.periph.rfPin == -1);

  // The IR pin is kept from pin commands, and only a free output pin can be it.
  run(core, "{\"cmd\":\"pin.mode\",\"pin\":6,\"mode\":\"out\"}");
  CHECK(has(run(core, "{\"cmd\":\"ir.pin\",\"pin\":6}"), "set pin.mode none first"));
  CHECK(has(run(core, "{\"cmd\":\"ir.pin\",\"pin\":16}"), "pin must be an output pin"));
  CHECK(has(run(core, "{\"cmd\":\"ir.pin\",\"pin\":true}"), "pin must be an output pin"));
  CHECK(has(run(core, "{\"cmd\":\"ir.pin\",\"pin\":3}"), "\"cmd\":\"ir.pin\",\"pin\":3"));
  CHECK(settings.periph.irPin == 3);
  CHECK(has(run(core, "{\"cmd\":\"pin.mode\",\"pin\":3,\"mode\":\"in\"}"), "pin not available"));
  CHECK(has(run(core, "{\"cmd\":\"gpio_write\",\"pin\":3,\"value\":1}"), "pin not allowed"));
  CHECK(!has(run(core, "{\"cmd\":\"describe\"}"), "{\"pin\":3,"));
  CHECK(has(run(core, "{\"cmd\":\"ir.pin\",\"pin\":-1}"), "\"cmd\":\"ir.pin\""));
  CHECK(settings.periph.irPin == -1);
  CHECK(has(run(core, "{\"cmd\":\"pin.mode\",\"pin\":3,\"mode\":\"in\"}"), "\"event\":\"ack\""));

  // The RF pin works the same way, and never shares a pin with IR.
  CHECK(has(run(core, "{\"cmd\":\"rf.pin\",\"pin\":3}"), "set pin.mode none first"));
  CHECK(has(run(core, "{\"cmd\":\"rf.pin\",\"pin\":16}"), "pin must be an output pin"));
  CHECK(has(run(core, "{\"cmd\":\"rf.pin\",\"pin\":7,\"id\":20}"), "\"cmd\":\"rf.pin\",\"pin\":7,\"id\":20"));
  CHECK(settings.periph.rfPin == 7 && core.rfPin() == 7);
  CHECK(has(run(core, "{\"cmd\":\"pin.mode\",\"pin\":7,\"mode\":\"out\"}"), "pin not available"));
  CHECK(!has(run(core, "{\"cmd\":\"describe\"}"), "{\"pin\":7,"));
  CHECK(has(run(core, "{\"cmd\":\"ir.pin\",\"pin\":7}"), "that pin is the RF pin"));
  CHECK(has(run(core, "{\"cmd\":\"ir.pin\",\"pin\":8}"), "\"cmd\":\"ir.pin\",\"pin\":8"));
  CHECK(has(run(core, "{\"cmd\":\"rf.pin\",\"pin\":8}"), "that pin is the IR pin"));
  CHECK(settings.periph.rfPin == 7);
  setup.fromSerial = false;
  CHECK(has(run(core, "{\"cmd\":\"rf.pin\",\"pin\":-1}"), "setup commands are only taken over USB"));
  setup.fromSerial = true;
  CHECK(has(run(core, "{\"cmd\":\"rf.pin\",\"pin\":-1}"), "\"cmd\":\"rf.pin\""));
  CHECK(settings.periph.rfPin == -1 && core.rfPin() == -1);

  // A rename tells the board to restart mDNS; the same name does not.
  int renames = setupHal.renames;
  run(core, "{\"cmd\":\"node.set\",\"name\":\"desk_board-2\"}");
  CHECK(setupHal.renames == renames);
  run(core, "{\"cmd\":\"node.set\",\"name\":\"hall\"}");
  CHECK(setupHal.renames == renames + 1);
}

// An output can start at the level an active-low relay needs, so it never
// clicks on while the board is set up.
static void testStartLevel() {
  FakeHal hal;
  Core core("test_node", "fw", BOARD_HOST, hal);
  CHECK(has(run(core, "{\"cmd\":\"pin.mode\",\"pin\":4,\"mode\":\"out\",\"value\":1,\"id\":1}"),
            "\"cmd\":\"pin.mode\",\"pin\":4,\"value\":1,\"id\":1"));
  CHECK(hal.levels[4] == std::vector<int>({1}));
  CHECK(has(run(core, "{\"cmd\":\"pin.read\",\"pin\":4}"), "\"value\":1"));
  // Without a value an output starts low, and the ack carries no value.
  std::string r = run(core, "{\"cmd\":\"pin.mode\",\"pin\":5,\"mode\":\"out\"}");
  CHECK(has(r, "\"cmd\":\"pin.mode\",\"pin\":5}"));
  CHECK(hal.levels[5] == std::vector<int>({0}));
  // Until pin.write chooses a level, a resent mode with a value sets it...
  CHECK(has(run(core, "{\"cmd\":\"pin.mode\",\"pin\":5,\"mode\":\"out\",\"value\":true}"), "\"value\":1"));
  CHECK(hal.digital[5] == 1);
  // ...and resending the level it already has writes nothing.
  run(core, "{\"cmd\":\"pin.mode\",\"pin\":4,\"mode\":\"out\",\"value\":1}");
  CHECK(hal.levels[4].size() == 1);
  // After pin.write, a resent setup keeps the level the host chose.
  run(core, "{\"cmd\":\"pin.write\",\"pin\":4,\"value\":0}");
  CHECK(has(run(core, "{\"cmd\":\"pin.mode\",\"pin\":4,\"mode\":\"out\",\"value\":1,\"id\":2}"),
            "\"pin\":4,\"value\":0,\"id\":2"));
  CHECK(hal.levels[4] == std::vector<int>({1, 0}));
  // A new mode forgets the choice: out again starts at the given level.
  run(core, "{\"cmd\":\"pin.mode\",\"pin\":4,\"mode\":\"in\"}");
  run(core, "{\"cmd\":\"pin.mode\",\"pin\":4,\"mode\":\"out\",\"value\":1}");
  CHECK(hal.levels[4] == std::vector<int>({1, 0, 1}));
  run(core, "{\"cmd\":\"pin.mode\",\"pin\":4,\"mode\":\"out\",\"value\":0}");
  CHECK(hal.digital[4] == 0);

  const char* bad[] = {"2", "-1", "\"1\"", "null", "0.5x"};
  for (unsigned i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
    std::string line = std::string("{\"cmd\":\"pin.mode\",\"pin\":6,\"mode\":\"out\",\"value\":") + bad[i] + "}";
    CHECK(has(run(core, line.c_str()), "\"event\":\"error\""));
  }
  CHECK(has(run(core, "{\"cmd\":\"pin.mode\",\"pin\":6,\"mode\":\"out\",\"value\":2}"), "value is 0 or 1"));
  CHECK(has(run(core, "{\"cmd\":\"pin.mode\",\"pin\":6,\"mode\":\"pwm\",\"value\":1}"), "value is only taken with mode out"));
  CHECK(hal.modes[6] == MODE_NONE && hal.levels[6].empty());

  // v1 gpio_write starts the output at the level it writes.
  run(core, "{\"cmd\":\"gpio_write\",\"pin\":9,\"value\":1}");
  CHECK(hal.levels[9][0] == 1);
}

// NEC timing: 9 ms + 4.5 ms header, 562 us marks, 562 or 1687 us spaces.
static void testNecTiming() {
  uint32_t bits = necFrame(4, 8);
  uint16_t mark, space;
  necPulse(bits, 0, &mark, &space);
  CHECK(mark == 9000 && space == 4500);
  unsigned long total = 0;
  for (int i = 0; i < NEC_PULSES; i++) {
    necPulse(bits, i, &mark, &space);
    if (i > 0) CHECK(mark == 562);
    if (i >= 1 && i <= 32) CHECK(space == (((bits >> (i - 1)) & 1) ? 1687 : 562));
    total += mark + space;
  }
  necPulse(bits, NEC_PULSES - 1, &mark, &space);
  CHECK(space == 0);
  // Address 4 and command 8 have 16 one bits, as any NEC frame has.
  CHECK(total == 9000 + 4500 + 33UL * 562 + 16UL * 1687 + 16UL * 562);
}

// RCSwitch::send, written out independently: the code most significant bit
// first as one or zero pulses, then the sync, in units of the pulse length.
static std::vector<int> rcswitchUnits(const char* bitString, int one[2], int zero[2], int sync[2]) {
  std::vector<int> units;
  for (const char* p = bitString; *p; p++) {
    int* pair = *p == '1' ? one : zero;
    units.push_back(pair[0]);
    units.push_back(pair[1]);
  }
  units.push_back(sync[0]);
  units.push_back(sync[1]);
  return units;
}

// RCSwitch::sendTriState: 0 is 00, F is 01 and 1 is 11.
static uint32_t triState(const char* word) {
  uint32_t code = 0;
  for (const char* p = word; *p; p++) code = (code << 2) | (*p == '1' ? 3 : *p == 'F' ? 1 : 0);
  return code;
}

static void testRfEncoding() {
  // RCSwitch's SendDemo sends one code three ways, and its type A switchOn
  // for group 11111 and device 00010 builds the same word.
  CHECK(triState("00000FFF0F0F") == 5393);
  CHECK(triState("00000FFF0FF0") == 5396);

  RfProtocol p;
  CHECK(!rfProtocol(0, &p) && !rfProtocol(4, &p) && !rfProtocol(-1, &p));
  // RCSwitch.cpp proto[]: pulse, sync, zero, one.
  CHECK(rfProtocol(1, &p) && p.number == 1 && p.pulseUs == 350 && p.syncHigh == 1 && p.syncLow == 31 &&
        p.zeroHigh == 1 && p.zeroLow == 3 && p.oneHigh == 3 && p.oneLow == 1);
  CHECK(rfProtocol(2, &p) && p.pulseUs == 650 && p.syncHigh == 1 && p.syncLow == 10 && p.zeroHigh == 1 &&
        p.zeroLow == 2 && p.oneHigh == 2 && p.oneLow == 1);
  CHECK(rfProtocol(3, &p) && p.pulseUs == 100 && p.syncHigh == 30 && p.syncLow == 71 && p.zeroHigh == 4 &&
        p.zeroLow == 11 && p.oneHigh == 9 && p.oneLow == 6);

  struct Case {
    int protocol;
    uint32_t code;
    uint8_t bits;
    const char* bitString;
  } cases[] = {
      {1, 5393, 24, "000000000001010100010001"},
      {1, 5396, 24, "000000000001010100010100"},
      {2, 5393, 24, "000000000001010100010001"},
      {3, 0xA5, 8, "10100101"},
      {1, 1, 1, "1"},
      {1, 0xFFFFFFFFUL, 32, "11111111111111111111111111111111"},
      {2, 0x80000001UL, 32, "10000000000000000000000000000001"},
  };
  for (unsigned c = 0; c < sizeof(cases) / sizeof(cases[0]); c++) {
    CHECK(rfProtocol(cases[c].protocol, &p));
    int one[2] = {p.oneHigh, p.oneLow}, zero[2] = {p.zeroHigh, p.zeroLow}, sync[2] = {p.syncHigh, p.syncLow};
    std::vector<int> want = rcswitchUnits(cases[c].bitString, one, zero, sync);
    std::vector<int> got;
    for (int i = 0; i <= cases[c].bits; i++) {
      uint16_t high, low;
      rfPulse(p, cases[c].code, cases[c].bits, i, &high, &low);
      got.push_back(high / p.pulseUs);
      got.push_back(low / p.pulseUs);
      CHECK(high % p.pulseUs == 0 && low % p.pulseUs == 0);
    }
    CHECK(got == want);
  }
  // Protocol 1 for 5393: a zero is 350 us high and 1050 us low, the sync
  // 350 us high and 10850 us low.
  rfProtocol(1, &p);
  uint16_t high, low;
  rfPulse(p, 5393, 24, 0, &high, &low);
  CHECK(high == 350 && low == 1050);
  rfPulse(p, 5393, 24, 23, &high, &low);
  CHECK(high == 1050 && low == 350);
  rfPulse(p, 5393, 24, 24, &high, &low);
  CHECK(high == 350 && low == 10850);
}

static void testRfSend() {
  FakeHal hal;
  Core core("test_node", "fw", BOARD_HOST, hal);
  CHECK(has(run(core, "{\"cmd\":\"rf.send\",\"code\":5393,\"bits\":24,\"id\":3}"), "\"cmd\":\"rf.send\",\"id\":3"));
  CHECK(hal.rf.size() == 1 && hal.rf[0].code == 5393 && hal.rf[0].bits == 24 && hal.rf[0].repeat == 10 &&
        hal.rf[0].protocol.number == 1 && hal.rf[0].protocol.pulseUs == 350);
  run(core, "{\"cmd\":\"rf.send\",\"code\":4294967295,\"bits\":32,\"protocol\":3,\"repeat\":20}");
  CHECK(hal.rf.size() == 2 && hal.rf[1].code == 0xFFFFFFFFUL && hal.rf[1].protocol.number == 3 && hal.rf[1].repeat == 20);
  run(core, "{\"cmd\":\"rf.send\",\"code\":0,\"bits\":1,\"protocol\":2,\"repeat\":1}");
  CHECK(hal.rf.size() == 3 && hal.rf[2].protocol.pulseUs == 650 && hal.rf[2].repeat == 1);

  struct Bad {
    const char* args;
    const char* error;
  } bad[] = {
      {"\"bits\":24", "needs code"},
      {"\"code\":5393", "needs code"},
      {"\"code\":-1,\"bits\":24", "needs code"},
      {"\"code\":4294967296,\"bits\":32", "needs code"},
      {"\"code\":12.5,\"bits\":24", "needs code"},
      {"\"code\":\"5393\",\"bits\":24", "needs code"},
      {"\"code\":5393,\"bits\":0", "bits is 1 to 32"},
      {"\"code\":5393,\"bits\":33", "bits is 1 to 32"},
      {"\"code\":256,\"bits\":8", "code has more bits than bits"},
      {"\"code\":1,\"bits\":8,\"protocol\":4", "protocol is 1 to 3"},
      {"\"code\":1,\"bits\":8,\"protocol\":0", "protocol is 1 to 3"},
      {"\"code\":1,\"bits\":8,\"repeat\":0", "repeat is 1 to 20"},
      {"\"code\":1,\"bits\":8,\"repeat\":21", "repeat is 1 to 20"},
  };
  for (unsigned i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
    std::string line = std::string("{\"cmd\":\"rf.send\",") + bad[i].args + ",\"id\":5}";
    std::string r = run(core, line.c_str());
    if (!has(r, bad[i].error) || !has(r, "\"id\":5}")) printf("rf.send %s -> %s", bad[i].args, r.c_str());
    CHECK(has(r, bad[i].error) && has(r, "\"id\":5}"));
  }
  CHECK(hal.rf.size() == 3);

  CHECK(has(run(core, "{\"cmd\":\"describe\"}"), "\"ir\":true,\"rf\":true,\"watches\":"));
  hal.rfPresent = false;
  CHECK(has(run(core, "{\"cmd\":\"describe\"}"), "\"rf\":false"));
  CHECK(has(run(core, "{\"cmd\":\"rf.send\",\"code\":1,\"bits\":8}"), "this board has no RF output"));
}

static void testU32() {
  Args a;
  uint32_t v = 7;
  CHECK(parseArgs("{\"a\":4294967295,\"b\":0,\"c\":-3,\"d\":1.5}", a) == 0);
  CHECK(a.u32("a", &v) && v == 0xFFFFFFFFUL);
  CHECK(a.u32("b", &v) && v == 0);
  CHECK(!a.u32("c", &v) && !a.u32("d", &v) && !a.u32("missing", &v));
  CHECK(parseArgs("{\"e\":true,\"f\":\"9\",\"g\":4294967296}", a) == 0);
  CHECK(!a.u32("e", &v) && !a.u32("f", &v) && !a.u32("g", &v));
}

// A hello goes out on every join and rejoin, and on a rename.
static void testLink() {
  Link link(30000);
  CHECK(link.update(false, 0) == 0);
  CHECK(link.update(true, 100) == (Link::START_UDP | Link::START_MDNS | Link::HELLO));
  CHECK(link.update(true, 200) == 0);
  CHECK(link.update(true, 30099) == 0);
  CHECK(link.update(true, 30100) == Link::HELLO);
  // A drop and a rejoin start everything again at once, not 30 s later.
  CHECK(link.update(false, 31000) == 0);
  CHECK(link.update(true, 32000) == (Link::START_UDP | Link::START_MDNS | Link::HELLO));
  CHECK(link.update(true, 33000) == 0);
  link.renamed();
  CHECK(link.update(true, 34000) == (Link::START_MDNS | Link::HELLO));
  CHECK(link.update(true, 35000) == 0);
  CHECK(link.update(true, 64000) == Link::HELLO);
  // wifi.set or wifi.clear: the next join is a fresh start, even if the
  // radio never reported a drop.
  link.reset();
  CHECK(link.update(true, 65000) == (Link::START_UDP | Link::START_MDNS | Link::HELLO));
  // A rename while down is covered by the start on the next join.
  link.renamed();
  CHECK(link.update(false, 66000) == 0);
  CHECK(link.update(true, 67000) == (Link::START_UDP | Link::START_MDNS | Link::HELLO));
  CHECK(link.update(true, 68000) == 0);
  // millis() wraps (after 49 days on a board); the period still holds.
  Link wrap(30000);
  unsigned long nearEnd = (unsigned long)-1 - 0xFFF;
  wrap.update(true, nearEnd);
  CHECK(wrap.update(true, nearEnd + 0x2000) == 0);
  CHECK(wrap.update(true, nearEnd + 30000) == Link::HELLO);
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

static void testNestedArgs() {
  Args a;
  CHECK(parseArgs("{\"cmd\":\"periph.set\",\"type\":\"nfc_rc522\",\"pins\":{\"ss\":10,\"rst\":-1},\"id\":3}", a) == 0);
  CHECK(a.count == 5);
  long v = 0;
  CHECK(a.num("pins.ss", &v) && v == 10);
  CHECK(a.num("pins.rst", &v) && v == -1);
  CHECK(a.num("id", &v) && v == 3);
  CHECK(!a.get("pins"));
  CHECK(parseArgs("{\"pins\":{},\"cmd\":\"x\"}", a) == 0 && a.count == 1 && strcmp(a.str("cmd"), "x") == 0);
  CHECK(parseArgs("{\"pins\" : { \"tx\" : 4 } }", a) == 0 && a.num("pins.tx", &v) && v == 4);
  // One level only, and still no arrays.
  CHECK(parseArgs("{\"a\":{\"b\":{\"c\":1}}}", a) != 0);
  CHECK(parseArgs("{\"a\":{\"b\":[1]}}", a) != 0);
  CHECK(parseArgs("{\"a\":{\"b\":1}", a) != 0);
  CHECK(parseArgs("{\"a\":{\"b\" 1}}", a) != 0);
  // The joined name has to fit a key.
  const char* error = parseArgs("{\"pins\":{\"abcdefg\":1}}", a);
  CHECK(error && strcmp(error, "value too long") == 0);
  CHECK(parseArgs("{\"pins\":{\"abcdef\":1}}", a) == 0);
}

static void testPeriphNames() {
  CHECK(periphFromName("ir") == PERIPH_IR && periphFromName("rf") == PERIPH_RF);
  CHECK(periphFromName("nfc_rc522") == PERIPH_NFC_RC522 && periphFromName("nfc_pn532") == PERIPH_NFC_PN532);
  CHECK(periphFromName("nfc") == PERIPH_NONE && periphFromName("") == PERIPH_NONE && periphFromName("IR") == PERIPH_NONE);
  CHECK(strcmp(periphName(PERIPH_NFC_RC522), "nfc_rc522") == 0 && periphName(PERIPH_NONE) == 0);
  CHECK(periphBuiltIn(PERIPH_IR) && periphBuiltIn(PERIPH_NFC_RC522) && !periphBuiltIn(PERIPH_NONE));
  CHECK(periphBuiltIn(PERIPH_NFC_PN532) == (OMNI_HAS_PN532 != 0));

  // An RC522 takes its own pins and the SPI bus; the Uno's also keeps 10.
  Periphs p = {-1, -1, PERIPH_NFC_RC522, 8, 9};
  int8_t pins[6];
  CHECK(periphPins(p, BOARD_UNO, PERIPH_NFC_RC522, pins) == 6);
  CHECK(pins[0] == 8 && pins[1] == 9 && pins[2] == 13 && pins[3] == 12 && pins[4] == 11 && pins[5] == 10);
  p.nfcSs = 10;
  p.nfcRst = -1;
  CHECK(periphPins(p, BOARD_UNO, PERIPH_NFC_RC522, pins) == 4 && pins[0] == 10);
  CHECK(periphPins(p, BOARD_ESP32, PERIPH_NFC_RC522, pins) == 4 && pins[1] == 18 && pins[2] == 19 && pins[3] == 23);
  CHECK(periphPins(p, BOARD_UNO, PERIPH_IR, pins) == 0);
  Periphs i2c = {-1, -1, PERIPH_NFC_PN532, -1, -1};
  CHECK(periphPins(i2c, BOARD_PICO_W, PERIPH_NFC_PN532, pins) == 2 && pins[0] == 4 && pins[1] == 5);
  CHECK(periphPins(i2c, BOARD_PICO_W, PERIPH_NFC_RC522, pins) == 0);

  CHECK(checkPeriphs(p, BOARD_UNO, PERIPH_NFC_RC522) == PERIPH_OK);
  p.nfcSs = 13;  // the SPI clock
  CHECK(checkPeriphs(p, BOARD_UNO, PERIPH_NFC_RC522) == PERIPH_SAME_PIN);
  p.nfcSs = 8;
  p.nfcRst = 8;
  CHECK(checkPeriphs(p, BOARD_UNO, PERIPH_NFC_RC522) == PERIPH_SAME_PIN);
  p.nfcRst = 1;  // the Uno's serial port
  CHECK(checkPeriphs(p, BOARD_UNO, PERIPH_NFC_RC522) == PERIPH_NOT_OUTPUT);
  p.nfcRst = -1;
  p.irPin = 12;
  CHECK(checkPeriphs(p, BOARD_UNO, PERIPH_NFC_RC522) == PERIPH_IS_IR);
  CHECK(checkPeriphs(p, BOARD_UNO, PERIPH_IR) == PERIPH_IS_NFC);
  p.irPin = 3;
  p.rfPin = 8;
  CHECK(checkPeriphs(p, BOARD_UNO, PERIPH_NFC_RC522) == PERIPH_IS_RF);
  CHECK(checkPeriphs(p, BOARD_UNO, PERIPH_IR) == PERIPH_OK);
  i2c.irPin = 21;
  CHECK(checkPeriphs(i2c, BOARD_ESP32, PERIPH_NFC_PN532) == PERIPH_IS_IR);
}

// periph.set and periph.clear on the host profile: SPI 13, 12, 11, I2C 14, 15.
static void testPeriphCommands() {
  FakeHal hal;
  Settings settings;
  memset(&settings, 0, sizeof(settings));
  settings.periph = {-1, -1, PERIPH_NONE, -1, -1};
  strcpy(settings.node, "bench");
  Core core(settings.node, "fw", BOARD_HOST, hal);
  FakeSetupHal setupHal;
  Setup setup(core, settings, setupHal, 38950);
  core.setExtension(&setup);

  const char* setLines[] = {"{\"cmd\":\"periph.set\",\"type\":\"ir\",\"pins\":{\"tx\":4}}",
                            "{\"cmd\":\"periph.clear\",\"type\":\"ir\"}"};
  for (unsigned i = 0; i < sizeof(setLines) / sizeof(setLines[0]); i++) {
    CHECK(has(run(core, setLines[i]), "setup commands are only taken over USB"));
  }
  CHECK(setupHal.saves == 0 && core.irPin() == -1);
  setup.fromSerial = true;

  // IR and RF through periph.set are the same as ir.pin and rf.pin.
  CHECK(run(core, "{\"cmd\":\"periph.set\",\"type\":\"ir\",\"pins\":{\"tx\":4},\"id\":1}") ==
        "{\"node\":\"bench\",\"event\":\"ack\",\"cmd\":\"periph.set\",\"type\":\"ir\",\"id\":1}\n");
  CHECK(settings.periph.irPin == 4 && core.irPin() == 4 && setupHal.saves == 1);
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"rf\",\"pins\":{\"tx\":4}}"), "that pin is the IR pin"));
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"rf\",\"pins\":{\"tx\":5}}"), "\"type\":\"rf\""));
  CHECK(core.rfPin() == 5);
  CHECK(has(run(core, "{\"cmd\":\"ir.pin\",\"pin\":5}"), "that pin is the RF pin"));
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"ir\",\"pins\":{\"tx\":16}}"), "pins must be output pins"));
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"ir\",\"pins\":{\"tx\":-1}}"), "pins must be output pins"));
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"ir\",\"pins\":{\"tx\":\"4\"}}"), "pins must be output pins"));
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"ir\",\"pins\":{\"tx\":300}}"), "pins must be output pins"));
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"ir\"}"), "needs pins.tx"));
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"ir\",\"pins\":4}"), "pins is an object"));
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"ir\",\"pins\":{\"ss\":4}}"), "pins has a name"));
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"nfc\",\"pins\":{}}"), "type is ir, rf, nfc_rc522 or nfc_pn532"));
  CHECK(has(run(core, "{\"cmd\":\"periph.clear\"}"), "type is ir, rf"));
  run(core, "{\"cmd\":\"pin.mode\",\"pin\":6,\"mode\":\"out\"}");
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"ir\",\"pins\":{\"tx\":6}}"), "set pin.mode none first"));
  CHECK(core.irPin() == 4);
  // Moving IR frees its old pin.
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"ir\",\"pins\":{\"tx\":7}}"), "\"event\":\"ack\""));
  CHECK(has(run(core, "{\"cmd\":\"pin.mode\",\"pin\":4,\"mode\":\"in\"}"), "\"event\":\"ack\""));
  run(core, "{\"cmd\":\"pin.mode\",\"pin\":4,\"mode\":\"none\"}");

  // An RC522 takes ss, rst and the SPI bus, all free and none an IR or RF pin.
  CHECK(hal.nfcStarts == 0);
  run(core, "{\"cmd\":\"pin.mode\",\"pin\":12,\"mode\":\"in\"}");
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"nfc_rc522\",\"pins\":{\"ss\":8,\"rst\":9}}"),
            "a pin the reader needs has a mode"));
  run(core, "{\"cmd\":\"pin.mode\",\"pin\":12,\"mode\":\"none\"}");
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"nfc_rc522\",\"pins\":{\"ss\":7}}"), "is the IR pin"));
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"nfc_rc522\",\"pins\":{\"ss\":11}}"), "neither on the SPI bus"));
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"nfc_rc522\",\"pins\":{\"ss\":8,\"rst\":8}}"), "two pins"));
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"nfc_rc522\",\"pins\":{\"rst\":9}}"), "pins.ss for nfc_rc522"));
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"nfc_rc522\",\"pins\":{\"ss\":8,\"rst\":99}}"), "pins must be output"));
  CHECK(hal.nfcStarts == 0 && settings.periph.nfc == PERIPH_NONE);
  CHECK(run(core, "{\"cmd\":\"periph.set\",\"type\":\"nfc_rc522\",\"pins\":{\"ss\":8,\"rst\":9},\"id\":7}") ==
        "{\"node\":\"bench\",\"event\":\"ack\",\"cmd\":\"periph.set\",\"type\":\"nfc_rc522\",\"id\":7}\n");
  CHECK(hal.nfcStarts == 1 && hal.nfcType == PERIPH_NFC_RC522 && hal.nfcSs == 8 && hal.nfcRst == 9);
  CHECK(settings.periph.nfc == PERIPH_NFC_RC522 && settings.periph.nfcSs == 8 && settings.periph.nfcRst == 9);
  const int taken[] = {8, 9, 11, 12, 13};
  std::string d = run(core, "{\"cmd\":\"describe\"}");
  for (unsigned i = 0; i < sizeof(taken) / sizeof(taken[0]); i++) {
    char pin[16];
    snprintf(pin, sizeof(pin), "{\"pin\":%d,", taken[i]);
    CHECK(!has(d, pin));
    char line[64];
    snprintf(line, sizeof(line), "{\"cmd\":\"pin.mode\",\"pin\":%d,\"mode\":\"out\"}", taken[i]);
    CHECK(has(run(core, line), "pin not available"));
  }
  CHECK(has(d, "\"periph\":[{\"type\":\"ir\",\"pins\":{\"tx\":7}},{\"type\":\"rf\",\"pins\":{\"tx\":5}},"
               "{\"type\":\"nfc_rc522\",\"pins\":{\"ss\":8,\"rst\":9,\"sck\":13,\"miso\":12,\"mosi\":11}}]"));
  CHECK(has(d, OMNI_HAS_PN532 ? "\"periphTypes\":[\"ir\",\"rf\",\"nfc_rc522\",\"nfc_pn532\"]"
                              : "\"periphTypes\":[\"ir\",\"rf\",\"nfc_rc522\"]"));
  CHECK(has(d, "\"ir\":true,\"rf\":true"));
  CHECK(has(run(core, "{\"cmd\":\"ir.pin\",\"pin\":13}"), "that pin is used by the NFC reader"));
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"rf\",\"pins\":{\"tx\":9}}"), "used by the NFC reader"));
  // Setting the same reader again with the same pins does not restart it.
  run(core, "{\"cmd\":\"periph.set\",\"type\":\"nfc_rc522\",\"pins\":{\"ss\":8,\"rst\":9}}");
  CHECK(hal.nfcStarts == 1);
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"nfc_rc522\",\"pins\":{\"ss\":10}}"), "\"event\":\"ack\""));
  CHECK(hal.nfcStarts == 2 && hal.nfcSs == 10 && hal.nfcRst == -1);
  CHECK(has(run(core, "{\"cmd\":\"describe\"}"), "{\"type\":\"nfc_rc522\",\"pins\":{\"ss\":10,\"sck\":13,"));
  CHECK(has(run(core, "{\"cmd\":\"pin.mode\",\"pin\":8,\"mode\":\"in\"}"), "\"event\":\"ack\""));
  run(core, "{\"cmd\":\"pin.mode\",\"pin\":8,\"mode\":\"none\"}");

#if OMNI_HAS_PN532
  // One reader at a time; the PN532 takes no pins of its own.
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"nfc_pn532\"}"), "periph.clear it first"));
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"nfc_pn532\",\"pins\":{\"ss\":3}}"), "pins has a name"));
#else
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"nfc_pn532\"}"), "has no driver for that type"));
#endif
  CHECK(run(core, "{\"cmd\":\"periph.clear\",\"type\":\"nfc_rc522\",\"id\":8}") ==
        "{\"node\":\"bench\",\"event\":\"ack\",\"cmd\":\"periph.clear\",\"type\":\"nfc_rc522\",\"id\":8}\n");
  CHECK(hal.nfcStarts == 3 && hal.nfcType == PERIPH_NONE && settings.periph.nfc == PERIPH_NONE);
  CHECK(has(run(core, "{\"cmd\":\"pin.mode\",\"pin\":13,\"mode\":\"out\"}"), "\"event\":\"ack\""));
  // Clearing what is not set is still an ack, and starts nothing.
  CHECK(has(run(core, "{\"cmd\":\"periph.clear\",\"type\":\"nfc_rc522\"}"), "\"event\":\"ack\""));
  CHECK(hal.nfcStarts == 3);
#if OMNI_HAS_PN532
  run(core, "{\"cmd\":\"pin.mode\",\"pin\":14,\"mode\":\"in\"}");
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"nfc_pn532\",\"pins\":{}}"), "a pin the reader needs has a mode"));
  run(core, "{\"cmd\":\"pin.mode\",\"pin\":14,\"mode\":\"none\"}");
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"nfc_pn532\",\"pins\":{}}"), "\"type\":\"nfc_pn532\""));
  CHECK(hal.nfcType == PERIPH_NFC_PN532 && hal.nfcSs == -1 && hal.nfcRst == -1);
  CHECK(has(run(core, "{\"cmd\":\"describe\"}"), "{\"type\":\"nfc_pn532\",\"pins\":{\"sda\":14,\"scl\":15}}]"));
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"nfc_rc522\",\"pins\":{\"ss\":8}}"), "periph.clear it first"));
  run(core, "{\"cmd\":\"periph.clear\",\"type\":\"nfc_pn532\"}");
#endif
  CHECK(has(run(core, "{\"cmd\":\"periph.clear\",\"type\":\"ir\"}"), "\"type\":\"ir\""));
  CHECK(has(run(core, "{\"cmd\":\"periph.clear\",\"type\":\"rf\"}"), "\"type\":\"rf\""));
  CHECK(core.irPin() == -1 && core.rfPin() == -1 && settings.periph.irPin == -1 && settings.periph.rfPin == -1);
  CHECK(has(run(core, "{\"cmd\":\"describe\"}"), "\"periph\":[],"));
}

// The Uno's SPI master keeps 10 as an output, so 10 is taken unless it is ss.
static void testUnoReader() {
  FakeHal hal;
  Settings settings;
  memset(&settings, 0, sizeof(settings));
  settings.periph = {-1, -1, PERIPH_NONE, -1, -1};
  Core core("uno", "fw", BOARD_UNO, hal);
  FakeSetupHal setupHal;
  Setup setup(core, settings, setupHal, 0);
  core.setExtension(&setup);
  setup.fromSerial = true;
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"nfc_rc522\",\"pins\":{\"ss\":8,\"rst\":9}}"), "\"event\":\"ack\""));
  CHECK(has(run(core, "{\"cmd\":\"describe\"}"), "\"pins\":{\"ss\":8,\"rst\":9,\"sck\":13,\"miso\":12,\"mosi\":11,\"hw_ss\":10}}"));
  CHECK(has(run(core, "{\"cmd\":\"pin.mode\",\"pin\":10,\"mode\":\"in\"}"), "pin not available"));
  CHECK(has(run(core, "{\"cmd\":\"periph.set\",\"type\":\"nfc_rc522\",\"pins\":{\"ss\":10,\"rst\":9}}"), "\"event\":\"ack\""));
  CHECK(has(run(core, "{\"cmd\":\"describe\"}"), "\"pins\":{\"ss\":10,\"rst\":9,\"sck\":13,\"miso\":12,\"mosi\":11}}"));
  CHECK(has(run(core, "{\"cmd\":\"pin.mode\",\"pin\":8,\"mode\":\"in\"}"), "\"event\":\"ack\""));
  // The longest periph.set fits the Uno's 96-byte line.
  CHECK(strlen("{\"cmd\":\"periph.set\",\"type\":\"nfc_rc522\",\"pins\":{\"ss\":10,\"rst\":9},\"id\":2147483647}") < 96);
}

static void testPeriphSettings() {
  Settings s;
  memset(&s, 0, sizeof(s));
  strcpy(s.node, "good");
  s.periph = {3, 7, PERIPH_NFC_RC522, 8, 9};
  sanitizeSettings(s, BOARD_HOST);
  CHECK(s.periph.irPin == 3 && s.periph.rfPin == 7 && s.periph.nfc == PERIPH_NFC_RC522);
  CHECK(s.periph.nfcSs == 8 && s.periph.nfcRst == 9);
  // A reader on the IR pin or its bus goes; IR and RF were there first.
  s.periph = {3, 7, PERIPH_NFC_RC522, 3, -1};
  sanitizeSettings(s, BOARD_HOST);
  CHECK(s.periph.irPin == 3 && s.periph.nfc == PERIPH_NONE && s.periph.nfcSs == -1);
  s.periph = {13, -1, PERIPH_NFC_RC522, 8, -1};
  sanitizeSettings(s, BOARD_HOST);
  CHECK(s.periph.irPin == 13 && s.periph.nfc == PERIPH_NONE);
  // Unwritten flash: no type, and a reset pin below -1 is none.
  s.periph = {-1, -1, 0xFF, 8, -1};
  sanitizeSettings(s, BOARD_HOST);
  CHECK(s.periph.nfc == PERIPH_NONE && s.periph.nfcSs == -1);
  s.periph = {-7, -9, PERIPH_NFC_RC522, 8, -100};
  sanitizeSettings(s, BOARD_HOST);
  CHECK(s.periph.irPin == -1 && s.periph.rfPin == -1 && s.periph.nfc == PERIPH_NFC_RC522 && s.periph.nfcRst == -1);
  s.periph = {-1, -1, PERIPH_NFC_PN532, 8, 9};
  sanitizeSettings(s, BOARD_ESP32);
  CHECK(s.periph.nfc == (OMNI_HAS_PN532 ? PERIPH_NFC_PN532 : PERIPH_NONE) && s.periph.nfcSs == -1 && s.periph.nfcRst == -1);
}

static void testNfcDebounce() {
  NfcDebounce d(1000);
  const uint8_t a[] = {0x04, 0xa1, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6};
  const uint8_t b[] = {0xde, 0xad, 0xbe, 0xef};
  CHECK(d.seen(a, 7, 5000));
  // Held on the reader: read again and again, reported once.
  for (unsigned long t = 5100; t < 9000; t += 100) CHECK(!d.seen(a, 7, t));
  // A missed read or two while held is not a new presentation.
  CHECK(!d.seen(a, 7, 9800));
  // Gone for a second, then back: a new presentation.
  CHECK(d.seen(a, 7, 10800));
  CHECK(!d.seen(a, 7, 10950));
  // Another tag is reported at once, and so is the first again after it.
  CHECK(d.seen(b, 4, 11000));
  CHECK(d.seen(a, 7, 11100));
  // The same first bytes with another length is another tag.
  CHECK(d.seen(a, 4, 11200));
  CHECK(!d.seen(a, 0, 20000) && !d.seen(a, 11, 20000));
  // millis() wrapping does not stop a held tag from being held.
  NfcDebounce w(1000);
  CHECK(w.seen(b, 4, (unsigned long)0 - 256));
  CHECK(!w.seen(b, 4, 0x50));
  CHECK(w.seen(b, 4, 0x50 + 1000));
}

// The core reads every NFC_POLL_MS and reports each presentation once.
static void testNfcPolling() {
  FakeHal hal;
  Core core("door", "fw", BOARD_HOST, hal);
  Capture out;
  hal.nfcUid = {0x04, 0xa1, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6};
  core.poll(out);
  CHECK(hal.nfcReads == 0);  // no reader set
  core.setPeriphs({-1, -1, PERIPH_NFC_RC522, 8, -1});
  core.poll(out);
  CHECK(out.take() == "{\"node\":\"door\",\"event\":\"nfc.scanned\",\"uid\":\"04a1b2c3d4e5f6\"}\n");
  CHECK(hal.nfcReads == 1);
  hal.now += 50;
  core.poll(out);
  CHECK(hal.nfcReads == 1);
  for (int i = 0; i < 30; i++) {
    hal.now += NFC_POLL_MS;
    core.poll(out);
  }
  CHECK(out.take().empty() && hal.nfcReads == 31);
  hal.nfcUid.clear();
  for (int i = 0; i < 10; i++) {
    hal.now += NFC_POLL_MS;
    core.poll(out);
  }
  CHECK(out.take().empty());
  hal.nfcUid = {0x04, 0xa1, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6};
  hal.now += NFC_POLL_MS;
  core.poll(out);
  CHECK(has(out.take(), "\"uid\":\"04a1b2c3d4e5f6\""));
  // A read still going is carried on at once on every poll.
  hal.nfcUid = {0xde, 0xad, 0xbe, 0xef};
  hal.busyReads = 2;
  hal.now += NFC_POLL_MS;
  int reads = hal.nfcReads;
  core.poll(out);
  core.poll(out);
  CHECK(out.take().empty());
  core.poll(out);
  CHECK(hal.nfcReads == reads + 3);
  CHECK(out.take() == "{\"node\":\"door\",\"event\":\"nfc.scanned\",\"uid\":\"deadbeef\"}\n");
  // Clearing the reader stops the reads.
  core.setPeriphs({-1, -1, PERIPH_NONE, -1, -1});
  reads = hal.nfcReads;
  hal.now += 10 * NFC_POLL_MS;
  core.poll(out);
  CHECK(hal.nfcReads == reads && hal.nfcType == PERIPH_NONE);
}

static void testCrcA() {
  // ISO 14443-3 annex B examples.
  uint8_t crc[2];
  const uint8_t zero[] = {0x00, 0x00};
  crcA(zero, 2, crc);
  CHECK(crc[0] == 0xA0 && crc[1] == 0x1E);
  const uint8_t data[] = {0x12, 0x34};
  crcA(data, 2, crc);
  CHECK(crc[0] == 0x26 && crc[1] == 0xCF);
  // HLTA, as every reader library sends it.
  const uint8_t halt[] = {0x50, 0x00};
  crcA(halt, 2, crc);
  CHECK(crc[0] == 0x57 && crc[1] == 0xCD);
}

// A type A tag behind a reader, answering the way ISO 14443-3 says.
class FakeTag : public NfcTransceiver {
 public:
  std::vector<uint8_t> uid;
  bool present = true, badBcc = false, badCrc = false, halted = false;
  int halts = 0;
  int transceive(const uint8_t* tx, int txLen, uint8_t txLastBits, uint8_t* rx, int rxMax) override {
    if (!present) return -1;
    if (txLen == 1 && txLastBits == 7 && tx[0] == 0x52) {
      halted = false;
      rx[0] = 0x44;
      rx[1] = 0x00;
      return 2;
    }
    if (txLastBits || halted) return -1;
    uint8_t crc[2];
    if (txLen == 4 && tx[0] == 0x50 && tx[1] == 0x00) {
      crcA(tx, 2, crc);
      if (crc[0] == tx[2] && crc[1] == tx[3]) {
        halted = true;
        halts++;
      }
      return -1;
    }
    int level = (tx[0] - 0x93) / 2;
    if (tx[0] < 0x93 || tx[0] > 0x97 || (tx[0] & 1) == 0) return -1;
    int levels = uid.size() == 4 ? 1 : uid.size() == 7 ? 2 : 3;
    if (level >= levels) return -1;
    uint8_t part[5];
    bool more = level < levels - 1;
    int from = level * 3;
    if (more) {
      part[0] = 0x88;
      memcpy(part + 1, &uid[from], 3);
    } else {
      memcpy(part, &uid[from], 4);
    }
    part[4] = part[0] ^ part[1] ^ part[2] ^ part[3];
    if (txLen == 2 && tx[1] == 0x20) {
      if (rxMax < 5) return -1;
      memcpy(rx, part, 5);
      if (badBcc) rx[4] ^= 1;
      return 5;
    }
    if (txLen == 9 && tx[1] == 0x70 && memcmp(tx + 2, part, 5) == 0) {
      crcA(tx, 7, crc);
      if (crc[0] != tx[7] || crc[1] != tx[8] || rxMax < 3) return -1;
      rx[0] = more ? 0x04 : 0x08;
      crcA(rx, 1, rx + 1);
      if (badCrc) rx[2] ^= 1;
      return 3;
    }
    return -1;
  }
};

static void testTypeA() {
  FakeTag tag;
  uint8_t uid[NFC_UID_MAX];
  const uint8_t four[] = {0xde, 0xad, 0xbe, 0xef};
  tag.uid.assign(four, four + 4);
  CHECK(readTypeAUid(tag, uid) == 4 && memcmp(uid, four, 4) == 0);
  CHECK(tag.halts == 1);
  // A halted tag is woken again, so it reads while it stays.
  CHECK(readTypeAUid(tag, uid) == 4 && tag.halts == 2);
  const uint8_t seven[] = {0x04, 0xa1, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6};
  tag.uid.assign(seven, seven + 7);
  CHECK(readTypeAUid(tag, uid) == 7 && memcmp(uid, seven, 7) == 0);
  const uint8_t ten[] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10};
  tag.uid.assign(ten, ten + 10);
  CHECK(readTypeAUid(tag, uid) == 10 && memcmp(uid, ten, 10) == 0);
  tag.badBcc = true;
  CHECK(readTypeAUid(tag, uid) == 0);
  tag.badBcc = false;
  tag.badCrc = true;
  CHECK(readTypeAUid(tag, uid) == 0);
  tag.badCrc = false;
  tag.present = false;
  CHECK(readTypeAUid(tag, uid) == 0);
}

#if OMNI_HAS_PN532
static void testPn532Frames() {
  uint8_t frame[16];
  // The frames every PN532 driver sends: GetFirmwareVersion, SAMConfiguration
  // normal mode, InListPassiveTarget for one 106 kbps type A target.
  const uint8_t version[] = {0x02};
  CHECK(pn532Frame(version, 1, frame) == 9);
  const uint8_t versionFrame[] = {0x00, 0x00, 0xFF, 0x02, 0xFE, 0xD4, 0x02, 0x2A, 0x00};
  CHECK(memcmp(frame, versionFrame, 9) == 0);
  const uint8_t sam[] = {0x14, 0x01, 0x14, 0x01};
  const uint8_t samFrame[] = {0x00, 0x00, 0xFF, 0x05, 0xFB, 0xD4, 0x14, 0x01, 0x14, 0x01, 0x02, 0x00};
  CHECK(pn532Frame(sam, 4, frame) == 12 && memcmp(frame, samFrame, 12) == 0);
  const uint8_t list[] = {0x4A, 0x01, 0x00};
  const uint8_t listFrame[] = {0x00, 0x00, 0xFF, 0x04, 0xFC, 0xD4, 0x4A, 0x01, 0x00, 0xE1, 0x00};
  CHECK(pn532Frame(list, 3, frame) == 11 && memcmp(frame, listFrame, 11) == 0);

  // A reply listing one tag with a 7-byte UID.
  uint8_t reply[] = {0x00, 0x00, 0xFF, 0x0F, 0xF1, 0xD5, 0x4B, 0x01, 0x01, 0x00, 0x44, 0x00,
                     0x07, 0x04, 0xa1, 0xb2, 0xc3, 0xd4, 0xe5, 0xf6, 0x00, 0x00};
  uint8_t sum = 0;
  for (int i = 5; i < 20; i++) sum = (uint8_t)(sum + reply[i]);
  reply[20] = (uint8_t)(0x100 - sum);
  const uint8_t* payload = 0;
  int n = pn532Payload(reply, sizeof(reply), &payload);
  CHECK(n == 14 && payload == reply + 6);
  uint8_t uid[NFC_UID_MAX];
  CHECK(pn532ListedUid(payload, n, uid) == 7 && uid[0] == 0x04 && uid[6] == 0xf6);
  // No tag in the field.
  const uint8_t none[] = {0x00, 0x00, 0xFF, 0x03, 0xFD, 0xD5, 0x4B, 0x00, 0xE0, 0x00};
  n = pn532Payload(none, sizeof(none), &payload);
  CHECK(n == 2 && pn532ListedUid(payload, n, uid) == 0);
  // Bad checksums, the ACK frame, truncation and a frame from the host are not replies.
  reply[20] ^= 1;
  CHECK(pn532Payload(reply, sizeof(reply), &payload) == -1);
  reply[20] ^= 1;
  reply[4] ^= 1;
  CHECK(pn532Payload(reply, sizeof(reply), &payload) == -1);
  reply[4] ^= 1;
  CHECK(pn532Payload(reply, 15, &payload) == -1);
  const uint8_t ack[] = {0x00, 0x00, 0xFF, 0x00, 0xFF, 0x00};
  CHECK(pn532Payload(ack, sizeof(ack), &payload) == -1);
  CHECK(pn532Payload(listFrame, sizeof(listFrame), &payload) == -1);
  // A UID length a type A tag cannot have.
  const uint8_t odd[] = {0x4B, 0x01, 0x01, 0x00, 0x44, 0x00, 0x05, 1, 2, 3, 4, 5};
  CHECK(pn532ListedUid(odd, sizeof(odd), uid) == 0);
  const uint8_t shortUid[] = {0x4B, 0x01, 0x01, 0x00, 0x44, 0x00, 0x07, 1, 2, 3};
  CHECK(pn532ListedUid(shortUid, sizeof(shortUid), uid) == 0);
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
  testStartLevel();
  testNecTiming();
  testRfEncoding();
  testRfSend();
  testU32();
  testLink();
  testNestedArgs();
  testPeriphNames();
  testPeriphCommands();
  testUnoReader();
  testPeriphSettings();
  testNfcDebounce();
  testNfcPolling();
  testCrcA();
  testTypeA();
#if OMNI_HAS_PN532
  testPn532Frames();
#endif
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
