# Dockerfile.python
FROM python:3.12-slim

# Установка зависимостей
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Копирование исходников
COPY python/ ./python/
COPY contracts/ ./contracts/

# Создание непривилегированного пользователя
RUN adduser --system --group --no-create-home appuser
USER appuser

# Точка входа
ENTRYPOINT ["python", "-m", "python"]
CMD ["dispatcher"]