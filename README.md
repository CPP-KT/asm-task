# Asm-task

## Задание
В этом репозитории есть пример программы на ассемблере:
* `add.asm` — это программа, которая выполняет сложение двух длинных чисел.

Вам необходимо разобраться в этом примере и написать на его основе программы, выполняющие вычитание и умножение беззнаковых длинных чисел.

Поскольку значительная часть их кода будет общей с `add.asm`, такой код вынесен в `common.asm`.
При сборке `add`, `sub` и `mul` содержимое `common.asm` [вставляется в начало](https://www.nasm.us/doc/nasmdoc2.html#section-2.1.19) соответствующих исходных файлов.

## Обзор
Для того, чтобы запустить примеры и написать своё решение, вам понадобится любой 64-битный дистрибутив Linux.

## Инструкция по работе
Все действия в инструкциях совершаются из корня репозитория.

* Модифицируйте файлы `sub.asm` и `mul.asm`, чтобы они выполняли вычитание и умножение.
* При необходимости собрать код без каких-либо файлов, закомментируйте в `CMakeLists.txt` строчки, связанные с ними (но не коммитьте эти изменения).

### Инструкция по сборке
```console
$ sudo apt install binutils g++ cmake nasm
$ ./build.sh
```

### Запуск примера
```console
$ ./build/add
10000000000000000000000000000000000000
100000000000000000000000000000000000000000000000000000000000000
100000000000000000000000010000000000000000000000000000000000000
```

## Примечания
1. `mul` и `sub` должны работать с беззнаковыми числами максимальной длины 128 qword (input). При этом результат `mul` (output) в данном случае может быть длины 256 qword и это должно корректно обрабатываться.
2. Уменьшаемое в `sub` всегда не меньше вычитаемого.
3. Программу можно реализовать по-разному, но если в вашем решении можно будет соптимизировать потребление памяти на стеке (или в `.data`), то вы будете вынуждены делать правки.
4. Вы не можете считывать числа, тратя на это больше памяти, чем требуется.
5. Оставляйте комментарии в коде, особенно если делаете что-то нетривиальное &mdash; это сильно упрощает проверку.

## Тесты в GitHub Actions
Если смотреть за выводом CI в реальном времени, GitHub может обрезать длинные числа. Так что если ожидаемые ответы на тесты `mul` выглядят подозрительно короткими, дождитесь окончания CI и обновите страницу. Или скачайте логи.
