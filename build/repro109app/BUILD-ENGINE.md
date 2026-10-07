# Engine из новых source outputs

Этот consumer переносит существующий MacRunner assembler в macrunner-app.
Он собирает только Contents/Resources/engine из выбранных результатов исходниковой
сборки. Swift-приложение, помощники и конечная подпись остаются отдельными шагами.
Нынешний рецепт не удостоверяет, что весь MacRunner.app уже воспроизведён.

## Входы

Сначала получить новые outputs из закреплённых рецептов hyperbridge,
macrunner-wine и dxmt. Для каждого сохранить RESULT, source/driver/lock SHA,
inventory outputs и версии инструментов. Проверить Wine через
check-arm64ec-dist.py из того же закреплённого Wine recipe и сохранить число
проверенных EC-модулей. Исторический engine выпуска не является новым source output.

engine-inputs.json содержит явные выбранные пути, разрешаемые относительно
этого JSON, и следующие поля:

| Поле | Требование |
|---|---|
| name | Имя source candidate |
| wine | Новый install prefix: bin/wine, bin/wineserver, lib/wine, share/wine |
| fex | Новые Windows/Unix outputs обоих переводчиков |
| graphics | Выбранные новые graphics outputs |
| dependencyRoots | Непустой список prefixes исходниковой сборки зависимостей |
| dlopenLibraries | Явно выбранные библиотеки, загружаемые по имени |
| licenseInputs | Непустой список name/path/sha256 закреплённых текстов лицензий |
| environment | Полное окружение запуска, подготовленное из закреплённого recipe |
| wineEntitlements | Исходниковый plist с ожидаемыми ключами ABI/JIT/Game Mode |
| wineEntitlementsSHA256 | Полный SHA256 этого plist, обязателен при deferred signing |
| graphicsMatrix | Матрица слоёв, модулей и доказательств capability, если она заявлена |
| stripTool, stripToolSHA256 | Закреплённый llvm-strip, только при --strip-pe |

Все пути и SHA выбираются из квитанций конкретной сборки, а не из установок
Homebrew и не из рабочего каталога автора. SHA entitlement intent закрепляется
в описи source inputs до assembly. Один hash не доказывает полноту ключей:
их состав ещё надо сверить с принятым loader recipe, не печатая значения
идентичности, отпечатки сертификатов или учётные данные.

## Один вызов перед финальной подписью

Из чистого клона macrunner-app, на macOS с toolchain выбранного producer:

```sh
python3 -I -B build/repro109app/assemble_engine.py work/engine-inputs.json work/engine --defer-signing
```

OUT должен быть новым каталогом. Чтобы вложить engine в уже собранный свежий
source app, тем же вызовом указать его новый Contents/Resources/engine как OUT.
Путь к native приложению и его own-source receipt определяет app producer.

--defer-signing не вызывает codesign, не читает подписи и не использует
идентичность владельца. Перед созданием OUT проверяет SHA и форму plist; после
копирования и изменения Mach-O снова проверяет pin. Точные исходные bytes
сохраняются в signing/wine-loader.entitlements.plist и входят в ENGINE.json
с полным SHA. report.signing.mode=DEFERRED_FOR_OWNER, actual_entitlements и
signature_validation=NOT_ENABLED, final_owner_signing_required=true.

Это пакет до финальной подписи. Случайные ad-hoc подписи линкера или входов
не считаются подтверждёнными: install_name_tool может сделать их негодными.
Режим не утверждает, что такой пакет уже допускается Gatekeeper или исполняется
с нужными ABI/JIT/Game Mode правами. Финальные подпись и нотаризация — у владельца;
после них необходимо проверить actual native loader, его ключи и final hashes.

Без --defer-signing остаётся прежний режим: изменённые Mach-O подписываются
ad hoc с исходными entitlements; ключи выбранного native Wine loader должны
совпасть с ожидаемым plist. Несовпадение остаётся отказом, значения в ошибку
не попадают. Проверка ключей не является проверкой доверенной подписи.

--strip-pe необязателен, допустим в любом порядке с --defer-signing. Он удаляет
DWARF только указанным SHA-pinned llvm-strip и сохраняет Wine builtin marker.
Без этого флага PE bytes consumer не меняет.

## Состав и границы

Поддерживаются legacy bin/wine-preloader и установленная multiarch раскладка:
bin/wine dispatcher, lib/wine/aarch64-unix/wine и wine-preloader. Отсутствие
native loader/preloader или wineserver остаётся отказом. В signed mode проверяется
native loader, а не dispatcher.

Все связанные и явно dlopen-библиотеки разрешаются только внутри выбранных
dependencyRoots; системные /usr/lib и /System не копируются. Вложенные зависимости
обходятся до конца. Коллизия leaf names, выход symlink за выбранный prefix и
несовпадение bytes уже имеющейся библиотеки остаются отказами. Absolute host
references проверяются после relocation.

Media consumer использует существующий набор GStreamer plugins/scanner из
той же исходниковой установки, включая deinterlace/videofilter для Wine 11.
verify_engine_media.py проверяет offline media factories на готовом engine;
такую реальную проверку запускает согласованный cloud producer, не этот local
offline suite. Наличие файлов не подтверждает рабочий media flow.

wine/share/wine копируется, но происхождение шрифтов и лицензий каждого
компонента требует отдельной source census. ENGINE.json честно сообщает
licenseCoverage=INPUTS_HASHED_COMPONENT_MAPPING_NOT_AUDITED. Stock MoltenVK,
D3D11 и наличие Vulkan файлов не закрывают Indiana fork и D3D12/DXIL.

## Offline проверки собственного кода

На любой машине с Python 3.9+:

```sh
mkdir -p work/engine-test-tmp
REPRO109_TEST_TMP="$PWD/work/engine-test-tmp" TMPDIR="$PWD/work/engine-test-tmp" python3 -I -B -m unittest discover -s build/repro109app -p 'test*engine.py'
REPRO109_TEST_TMP="$PWD/work/engine-test-tmp" TMPDIR="$PWD/work/engine-test-tmp" python3 -I -B -O -m unittest discover -s build/repro109app -p 'test*engine.py'
```

Tests используют синтетические bytes и mocked native tools, без Wine/GPU,
игр, downloads и исполнения сторонних компонентов. Они покрывают dependency/
media closure, обе Wine layouts, сохранение default signed checks и deferred
intent, malformed/empty/non-dictionary plist, digest drift, отказ до OUT/tools,
privacy ошибки и неизвестные/повторные CLI flags. Это не приёмка engine.

## Следующий продуктовый рубеж

На новых outputs построить engine-inputs.json по их receipts, выполнить ровно
этот consumer в чистом cloud job и сохранить unsigned source package, ENGINE.json
и полные bounded logs. Сверить с принятой опорой тем же function/section прибором,
объяснить каждое отличие и выполнить hb-stand-diff, hb-stand32, dxmt-stand,
app32-gate на собранном составе. Затем проверять финальный BUILD.md целиком.

Локальный перенос consumer, offline tests и готовый packet не означают
завершение (A)–(F). Выкладку и запуск задач делает куратор.
