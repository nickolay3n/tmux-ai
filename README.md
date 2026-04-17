# 🤖 AI-Assisted Terminal

Инструмент для автоматического анализа команд Linux с использованием NVIDIA NIM API. Позволяет выполнять команды и получать AI-анализ их вывода в реальном времени без блокировки терминала.

## ✨ Возможности

- 🚀 **Асинхронный анализ** - команды не зависают в ожидании ответа API
- 📊 **Разделённый интерфейс** - команды слева, анализ справа
- 🖱️ **Полная поддержка мыши** - прокрутка, выделение, копирование
- ⚡ **Мгновенное выполнение** - команды работают с обычной скоростью
- 🔄 **Фоновый режим** - анализ выполняется параллельно

## 📋 Требования

- Linux (Ubuntu/Debian/CentOS/RHEL)
- tmux >= 2.6
- curl
- jq
- xclip
- NVIDIA API ключ (бесплатный)

## 🚀 Быстрая установка

### 1. Установите зависимости

```bash
# Ubuntu/Debian
sudo apt update
sudo apt install tmux jq curl -y

# CentOS/RHEL
sudo yum install tmux jq curl -y



# Модель API (по умолчанию)
API_MODEL="meta/llama-3.3-70b-instruct"

# Максимальное количество токенов в ответе
API_MAX_TOKENS=500

# Длина обрезаемого вывода (символы)
MAX_OUTPUT_LENGTH=2000


Доступные модели NVIDIA
Модель	ID
Llama 3.3 70B	meta/llama-3.3-70b-instruct
Llama 3.1 8B	meta/llama-3.1-8b-instruct
Phi-3 Mini	microsoft/phi-3-mini-4k-instruct


Структура файлов

Файл                        Назначение
setup-ai-tmux.sh            Главный установочный скрипт
/tmp/analyze-command.sh     Скрипт анализа команд
/tmp/left-pane-bashrc       Конфигурация левой панели
~/.tmux.conf                Конфигурация tmux


## tmux
прокрутка в tmux возможна при зажатом shift

