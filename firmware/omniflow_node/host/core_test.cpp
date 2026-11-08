// Unit tests for the protocol core, built and run natively:
//   c++ -std=c++11 -Wall -Wextra -Werror -o /tmp/core_test host/core_test.cpp omni_core.cpp && /tmp/core_test
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
  void setMode(int pin, Mode mode) override { modes[pin] = mode; }
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

int main() {
  // NEC: LG power, the classic MSB-first 0x20DF10EF, is address 4, command 8.
  CHECK(necFrame(4, 8) == necFromMsbCode(0x20DF10EF));
  CHECK(necFrame(4, 8) == (0x04u | (0xFBu << 8) | (0x08u << 16) | (0xF7u << 24)));
  CHECK(necFrame(0x1234, 0x56) == (0x34u | (0x12u << 8) | (0x56u << 16) | (0xA9u << 24)));

  // Board profiles keep their reserved pins.
  CHECK(picoWCaps(25) == 0 && picoWCaps(23) == 0 && picoWCaps(29) == 0);
  CHECK(picoWCaps(26) & CAP_ADC);
  CHECK(esp32Caps(6) == 0 && esp32Caps(11) == 0);
  CHECK(esp32Caps(34) == (CAP_IN | CAP_ADC));
  CHECK(!(esp32Caps(4) & CAP_ADC));  // ADC2: not while Wi-Fi is on
  CHECK(esp8266Caps(17) == (CAP_IN | CAP_ADC) && esp8266Caps(1) == 0 && esp8266Caps(9) == 0);
  CHECK(unoCaps(0) == 0 && unoCaps(1) == 0);
  CHECK((unoCaps(9) & CAP_PWM) && !(unoCaps(8) & CAP_PWM));

  FakeHal hal;
  Core core("test_node", "omniflow-node/2 test", BOARD_PICO_W, hal);
  Capture out;

  core.handleLine("{\"cmd\":\"describe\",\"id\":1}", out);
  std::string d = out.take();
  CHECK(has(d, "\"event\":\"describe\""));
  CHECK(has(d, "\"proto\":2"));
  CHECK(has(d, "\"board\":\"pico_w\""));
  CHECK(has(d, "{\"pin\":26,\"caps\":[\"in\",\"out\",\"pwm\",\"servo\",\"adc\"]}"));
  CHECK(!has(d, "{\"pin\":25,"));
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

  // Bad input never crashes and always answers.
  const char* junk[] = {"", "not json", "{", "{\"cmd\":}", "{\"cmd\":\"x\",\"a\":{\"b\":1}}", "[1,2]",
                        "{\"cmd\":\"teleport\"}", "{\"id\":3}"};
  for (unsigned i = 0; i < sizeof(junk) / sizeof(junk[0]); i++) {
    core.handleLine(junk[i], out);
    CHECK(has(out.take(), "\"event\":\"error\""));
  }

  hal.now = 125000;
  core.hello(out, 38950);
  CHECK(out.take() ==
        "{\"node\":\"test_node\",\"event\":\"hello\",\"proto\":2,\"board\":\"pico_w\",\"port\":38950,\"up\":125,\"set\":6}\n");

  if (failures) {
    printf("%d check(s) failed\n", failures);
    return 1;
  }
  printf("all core checks passed\n");
  return 0;
}
