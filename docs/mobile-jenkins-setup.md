# Mobile Jenkins Setup — Flutter Android CI

This documents the one-time setup of the Flutter + Android build environment on the Jenkins server (dm-prd, 51.79.156.217).

## Prerequisites (already installed)

- Java 17: `sudo apt install openjdk-17-jdk`
- Ruby 3.3+: `sudo apt install ruby ruby-dev build-essential`

## Installation steps completed

### 1. Flutter SDK
```bash
sudo git clone --depth=1 --branch stable https://github.com/flutter/flutter.git /opt/flutter
sudo chown -R root:jenkins /opt/flutter
sudo chmod -R g+rwx /opt/flutter
sudo -u jenkins git config --global --add safe.directory /opt/flutter
```

### 2. Android SDK
```bash
wget https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip
sudo mkdir -p /opt/android-sdk/cmdline-tools/latest
sudo unzip commandlinetools-linux-11076708_latest.zip -d /tmp/cmdline
sudo mv /tmp/cmdline/cmdline-tools/* /opt/android-sdk/cmdline-tools/latest/
sudo chown -R root:jenkins /opt/android-sdk
sudo chmod -R g+rwx /opt/android-sdk

export ANDROID_SDK_ROOT=/opt/android-sdk
export PATH=$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$PATH
yes | sdkmanager --licenses
sdkmanager "platform-tools" "build-tools;35.0.0" "platforms;android-35" "platforms;android-34"

# android-36 required by Flutter 3.41.9+ — installed as jenkins user for write access
sudo -u jenkins bash -c "HOME=/var/lib/jenkins ANDROID_SDK_ROOT=/opt/android-sdk /opt/android-sdk/cmdline-tools/latest/bin/sdkmanager 'platforms;android-36'" <<< "y"
```

### 3. Make ubuntu home readable (Flutter looks there for Android SDK discovery)
```bash
sudo chmod 755 /home/ubuntu
sudo chmod -R 755 /home/ubuntu/.android
```

### 4. fastlane
```bash
sudo apt install ruby ruby-dev build-essential
sudo gem install fastlane --no-document
```

### 5. System-wide PATH profile
```bash
sudo tee /etc/profile.d/flutter-android.sh > /dev/null <<'EOF'
export FLUTTER_HOME=/opt/flutter
export ANDROID_SDK_ROOT=/opt/android-sdk
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
export PATH=$FLUTTER_HOME/bin:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$ANDROID_SDK_ROOT/platform-tools:/usr/local/bin:$PATH
EOF
sudo chmod +x /etc/profile.d/flutter-android.sh
```

### 6. Flutter precache (pre-downloads Android artifacts)
```bash
# Make ubuntu home readable first (step 3), then:
sudo -u jenkins bash -c "HOME=/var/lib/jenkins ANDROID_SDK_ROOT=/opt/android-sdk ANDROID_HOME=/opt/android-sdk /opt/flutter/bin/flutter precache --android"
sudo -u jenkins bash -c "HOME=/var/lib/jenkins ANDROID_SDK_ROOT=/opt/android-sdk ANDROID_HOME=/opt/android-sdk /opt/flutter/bin/flutter doctor --android-licenses" <<< "y
y
y
y
y"
```

## Verification

```bash
sudo -u jenkins bash -c "HOME=/var/lib/jenkins ANDROID_SDK_ROOT=/opt/android-sdk ANDROID_HOME=/opt/android-sdk JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64 /opt/flutter/bin/flutter doctor"
# Expected: [✓] Android toolchain - develop for Android devices
sudo -u jenkins /usr/local/bin/fastlane --version
# Expected: fastlane 2.233.1
```

## Jenkins credentials required

Add these in **Manage Jenkins → Credentials → System → Global** (Kind: Secret file):

| Credential ID         | Kind        | Description                                      |
|-----------------------|-------------|--------------------------------------------------|
| `ANDROID_KEYSTORE`    | Secret file | `dvarpal.jks` — Android signing keystore         |
| `GOOGLE_PLAY_JSON_KEY`| Secret file | Google Play service account JSON (upload access) |

## Installed locations

| Component       | Path                                             |
|-----------------|--------------------------------------------------|
| Flutter SDK     | `/opt/flutter`                                   |
| Android SDK     | `/opt/android-sdk`                               |
| fastlane        | `/usr/local/bin/fastlane`                        |
| Java 17         | `/usr/lib/jvm/java-17-openjdk-amd64`             |
| Platforms       | `android-34`, `android-35`, `android-36`         |
| Build tools     | `35.0.0`                                         |
