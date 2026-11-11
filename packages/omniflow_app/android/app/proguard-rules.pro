# usb-serial-for-android finds each driver's supported devices by reflection
# (getSupportedDevices), which shrinking would otherwise remove.
-keep class com.hoho.android.usbserial.driver.** { *; }
