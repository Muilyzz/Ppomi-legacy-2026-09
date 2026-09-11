import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync, readdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const shell = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const project = resolve(shell, 'src-tauri/gen/android');
const cli = resolve(shell, 'node_modules/.bin/tauri');
if (!existsSync(resolve(project, 'settings.gradle')) || process.argv.includes('--regenerate')) {
  execFileSync(cli, ['android', 'init', '--ci', '--skip-targets-install'], { cwd: shell, stdio: 'inherit' });
}
function update(path, transform) {
  const target = resolve(project, path);
  const previous = readFileSync(target, 'utf8');
  const next = transform(previous);
  if (next !== previous) writeFileSync(target, next);
}
update('build.gradle.kts', value => {
  value = value.replace(/com\.android\.tools\.build:gradle:[^"]+/g, 'com.android.tools.build:gradle:8.7.3')
    .replace(/org\.jetbrains\.kotlin:kotlin-gradle-plugin:[^"]+/g, 'org.jetbrains.kotlin:kotlin-gradle-plugin:2.2.21');
  if (!value.includes('compose-compiler-gradle-plugin')) {
    value = value.replace('classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.2.21")',
      'classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.2.21")\n        classpath("org.jetbrains.kotlin:compose-compiler-gradle-plugin:2.2.21")');
  }
  if (!value.includes('// Ppomi Android SDK')) {
    value += `\n// Ppomi Android SDK: use the same API 35 SDK as the canonical native executor.\n// Configure the dependency project without editing downloaded Tauri sources.\nsubprojects {\n    afterEvaluate {\n        extensions.findByType<com.android.build.gradle.BaseExtension>()?.compileSdkVersion(35)\n    }\n}\n`;
  }
  return value;
});
update('buildSrc/build.gradle.kts', value => value.replace(/com\.android\.tools\.build:gradle:[^"]+/g, 'com.android.tools.build:gradle:8.7.3'));
// The node CLI's generated callback can contain `node tauri`, which is not a module
// relative to src-tauri. Resolve the installed CLI from that working directory.
const buildTask = readdirSync(resolve(project, 'buildSrc/src'), { recursive: true })
  .find(path => path.endsWith('BuildTask.kt'));
if (!buildTask) throw new Error('Generated Android Rust BuildTask is missing.');
update(`buildSrc/src/${buildTask}`, value => value
  .replace(/val executable = .*?;/, 'val executable = """node""";')
  .replace(/val args = listOf\([^;]+;/,
    'val args = listOf("../node_modules/@tauri-apps/cli/tauri.js", "android", "android-studio-script");'));
update('gradle/wrapper/gradle-wrapper.properties', value => value.replace(/gradle-[\d.]+-bin.zip/, 'gradle-8.11.1-bin.zip'));
update('app/build.gradle.kts', value => value
  .replace(/compileSdk = \d+/, 'compileSdk = 35')
  .replace(/minSdk = \d+/, 'minSdk = 28')
  .replace(/targetSdk = \d+/, 'targetSdk = 35')
  .replace(/androidx\.webkit:webkit:[^"]+/, 'androidx.webkit:webkit:1.12.1')
  .replace(/androidx\.appcompat:appcompat:[^"]+/, 'androidx.appcompat:appcompat:1.7.0')
  .replace(/androidx\.activity:activity-ktx:[^"]+/, 'androidx.activity:activity-ktx:1.9.3')
  .replace(/androidx\.lifecycle:lifecycle-process:[^"]+/, 'androidx.lifecycle:lifecycle-process:2.8.7')
);
update('app/src/main/AndroidManifest.xml', value => {
  if (!value.includes('android:allowBackup=')) value = value.replace('<application',
    '<application\n        android:allowBackup="false"\n        android:dataExtractionRules="@xml/data_extraction_rules"');
  if (!value.includes('android:windowSoftInputMode=')) value = value.replace('android:launchMode="singleTask"',
    'android:launchMode="singleTask"\n            android:windowSoftInputMode="adjustResize"');
  return value;
});
console.log('Android shell prepared (API 35, min 28, shared Kotlin/Compose and native service manifest).');
console.log('Build with: tauri android build --target aarch64 --apk');
