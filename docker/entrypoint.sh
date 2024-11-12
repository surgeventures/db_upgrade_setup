#!/bin/bash
# entrypoint.sh

# Function to calculate SHA of Elixir project files
calculate_sha() {
    find . \( \
        -name "*.ex" -o \
        -name "*.exs" -o \
        -name "*.eex" -o \
        -name "*.leex" -o \
        -name "*.heex" -o \
        -name "mix.exs" -o \
        -name "mix.lock" \
    \) \
    -not -path "./_build/*" \
    -not -path "./deps/*" \
    -not -path "./cover/*" \
    -not -path "./doc/*" \
    -not -path "./.elixir_ls/*" \
    -print0 | \
    sort -z | \
    xargs -0 sha256sum | \
    sha256sum | \
    cut -d' ' -f1
}

# Directory to store SHA
SHA_DIR="../elixir_app/.sha"
SHA_FILE="${SHA_DIR}/current.sha"

# Create SHA directory if it doesn't exist
mkdir -p "${SHA_DIR}"

# Calculate current SHA
CURRENT_SHA=$(calculate_sha)

# Check if SHA file exists and compare
if [ -f "${SHA_FILE}" ]; then
    STORED_SHA=$(cat "${SHA_FILE}")
    if [ "${CURRENT_SHA}" != "${STORED_SHA}" ]; then
        echo "Elixir source files changed. Rebuilding..."
        # Store new SHA before rebuild
        echo "${CURRENT_SHA}" > "${SHA_FILE}"
        # Rebuild the image
        docker-compose build
    else
        echo "No changes detected. Using existing image."
    fi
else
    echo "First run. Storing SHA and building..."
    echo "${CURRENT_SHA}" > "${SHA_FILE}"
    docker-compose build
fi

# Start the application
docker-compose up -d