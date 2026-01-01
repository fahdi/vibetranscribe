# VibeTranscribe Test Suite

## Overview

Comprehensive TDD test suite for VibeTranscribe CLI using pytest.

## Test Results

✅ **16 tests total - ALL PASSED**
- 15 unit/mock tests (fast)
- 1 integration test with real audio (slow)

### Coverage
- **summarize.py**: 92% coverage
- All critical paths tested

---

## Running Tests

### Quick Tests (no audio processing)
```bash
cd cli
source venv/bin/activate

# Run all fast tests
pytest -v -m "not slow"

# Run with coverage
pytest -v --cov=. --cov-report=html

# Run specific test class
pytest -v test_vibetranscribe.py::TestSummarization
```

### Integration Tests (with real audio)
```bash
# Run slow tests (requires Whisper model download)
pytest -v -m "slow"

# Run specific integration test
pytest -v test_vibetranscribe.py::TestCLIIntegration::test_real_transcription_tiny_model
```

### All Tests
```bash
# Run everything
pytest -v
```

---

## Test Coverage

### TestSummarization (5 tests)
- ✅ `test_summarize_text_short` - Short summary generation with mocked OpenAI
- ✅ `test_summarize_text_no_api_key` - Error handling for missing API key
- ✅ `test_summarize_text_medium` - Medium summary generation
- ✅ `test_format_summary_text` - Text output formatting
- ✅ `test_format_summary_markdown` - Markdown output formatting

### TestTranscription (3 tests)
- ✅ `test_transcribe_audio_exists` - Verify REC007.WAV exists
- ✅ `test_transcribe_with_mock` - Mocked transcription
- ✅ `test_transcribe_nonexistent_file` - Error handling for missing files

### TestFileIO (2 tests)
- ✅ `test_output_text_file` - Save transcription to text file
- ✅ `test_output_markdown_file` - Save to markdown file

### TestCLIIntegration (2 tests)
- ✅ `test_real_transcription_tiny_model` - Real Whisper transcription with REC007.WAV (slow)
- ✅ `test_cli_help` - CLI help command works

### TestErrorHandling (3 tests)
- ✅ `test_invalid_model_size` - Handle invalid model names
- ✅ `test_invalid_summary_length` - Default to short for invalid lengths
- ✅ `test_empty_transcription` - Handle empty transcriptions

### TestGeneratedSamples (1 test + parametrized)
- ✅ `test_generated_samples_exist` - Verify test samples created
- 🔄 `test_transcribe_generated_samples` - Test each language (parametrized, marked slow)

---

## Test Fixtures

### Audio Files Used
1. **REC007.WAV** - Your real Urdu audio sample (primary test file)
2. **generated/*.mp3** - 7 generated multilingual samples

### Temporary Files
- Tests use `tmp_path` fixture for file I/O tests
- No side effects on actual files

---

## Mocking Strategy

### OpenAI API
- All summarization tests use `mocker.patch('summarize.OpenAI')`
- No actual API calls during fast tests
- Realistic mock responses for testing parsing logic

### Whisper Model
- Fast tests mock the pipeline
- Slow tests use real tiny model
- MPS acceleration tested in integration tests

---

## Test Markers

### `@pytest.mark.slow`
- Tests that require model download
- Real audio transcription
- Skip with: `pytest -m "not slow"`

### `@pytest.mark.integration`
- Full end-to-end tests
- Not currently used (reserved for future)

---

## Real Test Output (REC007.WAV)

Integration test successfully transcribed REC007.WAV:

**Result:**
> "I am very happy to talk to you about this..."

✅ Proves end-to-end pipeline works with real audio

---

## Coverage Report

Generate detailed HTML coverage report:
```bash
pytest --cov=. --cov-report=html
open htmlcov/index.html
```

Current coverage:
- `summarize.py`: 92%
- `vibetranscribe.py`: 22% (CLI code harder to test, integration tests needed)
- Overall: Adequate coverage for critical business logic

---

## CI/CD Ready

Tests are ready for continuous integration:
- No external dependencies for fast tests
- Clear separation of fast vs slow tests
- Mock-based unit tests run in <10 seconds
- Integration tests optional (can download models in CI)

### Example GitHub Actions
```yaml
- name: Run tests
  run: |
    pip install -r requirements.txt
    pip install -r requirements-test.txt
    pytest -v -m "not slow"  # Skip slow tests in CI
```

---

## Adding New Tests

### Test Template
```python
def test_new_feature(mocker):
    """Test description"""
    # Arrange
    mock = mocker.patch('module.function')
    mock.return_value = "expected"
    
    # Act
    result = function_under_test()
    
    # Assert
    assert result == "expected"
    mock.assert_called_once()
```

### Running Single Test
```bash
pytest -v test_vibetranscribe.py::TestClass::test_method -s
```

---

## Next Steps

- [ ] Add performance benchmarks
- [ ] Test batch processing (when implemented)
- [ ] Add snapshot tests for outputs
- [ ] Test with more audio formats
- [ ] Increase CLI integration coverage
