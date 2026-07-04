# Recovered from image history (localhost/retrieval-tool:v1) after the
# original Dockerfile was lost. openSUSE BCI Python base + venv.
FROM registry.opensuse.org/opensuse/bci/python:3.12

ENV VIRTUAL_ENV=/opt/venv
RUN python3 -m venv "$VIRTUAL_ENV"
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

WORKDIR /app
COPY retrieval_tool.py /app/retrieval_tool.py

EXPOSE 8000
CMD ["uvicorn", "retrieval_tool:app", "--host", "0.0.0.0", "--port", "8000"]
