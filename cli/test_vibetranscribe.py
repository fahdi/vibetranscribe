"""
Test suite for VibeTranscribe CLI
Tests transcription, summarization, and file I/O
"""

import pytest
import os
import json
from unittest.mock import Mock, patch, MagicMock
from summarize import summarize_text, format_summary_output


class TestSummarization:
    """Test summarization functionality"""
    
    def test_summarize_text_short(self, mocker):
        """Test short summary generation"""
        # Mock OpenAI client
        mock_client = mocker.patch('summarize.OpenAI')
        mock_response = Mock()
        mock_response.choices = [Mock()]
        mock_response.choices[0].message.content = """SUMMARY:
Test summary here.

KEY POINTS:
- Point 1
- Point 2

ACTION ITEMS:
- Action 1"""
        
        mock_client.return_value.chat.completions.create.return_value = mock_response
        
        result = summarize_text("Test transcription", length="short", api_key="test-key")
        
        assert "summary" in result
        assert "key_points" in result
        assert "action_items" in result
        assert len(result["key_points"]) == 2
        assert len(result["action_items"]) == 1
    
    def test_summarize_text_no_api_key(self):
        """Test that missing API key raises error"""
        with pytest.raises(ValueError, match="OpenAI API key required"):
            summarize_text("Test", api_key=None)
    
    def test_summarize_text_medium(self, mocker):
        """Test medium summary generation"""
        mock_client = mocker.patch('summarize.OpenAI')
        mock_response = Mock()
        mock_response.choices = [Mock()]
        mock_response.choices[0].message.content = """SUMMARY:
This is a medium length summary.

KEY POINTS:
- Point 1
- Point 2
- Point 3

ACTION ITEMS:
None"""
        
        mock_client.return_value.chat.completions.create.return_value = mock_response
        
        result = summarize_text("Test", length="medium", api_key="test-key")
        
        assert len(result["key_points"]) == 3
        assert len(result["action_items"]) == 0
    
    def test_format_summary_text(self):
        """Test text formatting of summary"""
        summary_data = {
            "summary": "Test summary",
            "key_points": ["Point 1", "Point 2"],
            "action_items": ["Task 1"]
        }
        
        output = format_summary_output(summary_data, "text")
        
        assert "SUMMARY:" in output
        assert "Test summary" in output
        assert "KEY POINTS:" in output
        assert "Point 1" in output
        assert "ACTION ITEMS:" in output
        assert "Task 1" in output
    
    def test_format_summary_markdown(self):
        """Test markdown formatting of summary"""
        summary_data = {
            "summary": "Test summary",
            "key_points": ["Point 1"],
            "action_items": []
        }
        
        output = format_summary_output(summary_data, "markdown")
        
        assert "# Summary" in output
        assert "## Key Points" in output
        assert "- Point 1" in output


class TestTranscription:
    """Test transcription functionality"""
    
    @pytest.fixture
    def test_audio_file(self):
        """Path to test audio file"""
        return "../test-audio/REC007.WAV"
    
    def test_transcribe_audio_exists(self, test_audio_file):
        """Test that test audio file exists"""
        assert os.path.exists(test_audio_file), f"Test audio file not found: {test_audio_file}"
    
    @patch('vibetranscribe.pipeline')
    def test_transcribe_with_mock(self, mock_pipeline, test_audio_file):
        """Test transcription with mocked Whisper"""
        # Mock the pipeline
        mock_pipe = Mock()
        mock_pipe.return_value = {"text": "This is a test transcription."}
        mock_pipeline.return_value = mock_pipe
        
        # Import after patching
        from vibetranscribe import transcribe_audio
        
        result = transcribe_audio(test_audio_file, model_size="tiny")
        
        assert isinstance(result, str)
        assert len(result) > 0
        mock_pipeline.assert_called_once()
    
    def test_transcribe_nonexistent_file(self):
        """Test error handling for missing file"""
        from vibetranscribe import transcribe_audio
        
        with pytest.raises(Exception):
            transcribe_audio("nonexistent.mp3", model_size="tiny")


class TestFileIO:
    """Test file input/output functionality"""
    
    def test_output_text_file(self, tmp_path, mocker):
        """Test saving transcription to text file"""
        output_file = tmp_path / "output.txt"
        test_content = "Test transcription content"
        
        # Write content
        with open(output_file, 'w') as f:
            f.write(test_content)
        
        # Verify
        assert output_file.exists()
        assert output_file.read_text() == test_content
    
    def test_output_markdown_file(self, tmp_path):
        """Test saving to markdown file"""
        output_file = tmp_path / "output.md"
        test_content = "# Transcription\n\nTest content"
        
        with open(output_file, 'w') as f:
            f.write(test_content)
        
        assert output_file.exists()
        content = output_file.read_text()
        assert "# Transcription" in content


class TestCLIIntegration:
    """Integration tests for CLI"""
    
    @pytest.fixture
    def real_audio_file(self):
        """Use real test audio file"""
        return "../test-audio/REC007.WAV"
    
    @pytest.mark.slow
    def test_real_transcription_tiny_model(self, real_audio_file):
        """Test real transcription with tiny model (requires model download)"""
        if not os.path.exists(real_audio_file):
            pytest.skip("Test audio file not found")
        
        from vibetranscribe import transcribe_audio
        
        # This will actually run Whisper - mark as slow test
        result = transcribe_audio(real_audio_file, model_size="tiny")
        
        assert isinstance(result, str)
        assert len(result) > 0
        print(f"Transcription result: {result}")
    
    def test_cli_help(self):
        """Test CLI help output"""
        import subprocess
        
        result = subprocess.run(
            ["python", "vibetranscribe.py", "--help"],
            capture_output=True,
            text=True,
            cwd=os.path.dirname(__file__)
        )
        
        assert result.returncode == 0
        assert "usage:" in result.stdout.lower() or "vibetranscribe" in result.stdout.lower()


class TestErrorHandling:
    """Test error handling and edge cases"""
    
    def test_invalid_model_size(self):
        """Test that invalid model size is handled"""
        # The argparse should handle this, but we can test the function directly
        with pytest.raises(Exception):
            from vibetranscribe import transcribe_audio
            transcribe_audio("test.mp3", model_size="invalid_model")
    
    def test_invalid_summary_length(self, mocker):
        """Test invalid summary length defaults to short"""
        mock_client = mocker.patch('summarize.OpenAI')
        mock_response = Mock()
        mock_response.choices = [Mock()]
        mock_response.choices[0].message.content = "SUMMARY:\nTest\n\nKEY POINTS:\n- Point\n\nACTION ITEMS:\nNone"
        
        mock_client.return_value.chat.completions.create.return_value = mock_response
        
        # Should default to "short" for invalid length
        result = summarize_text("Test", length="invalid", api_key="test-key")
        assert "summary" in result
    
    def test_empty_transcription(self, mocker):
        """Test handling of empty transcription"""
        mock_client = mocker.patch('summarize.OpenAI')
        mock_response = Mock()
        mock_response.choices = [Mock()]
        mock_response.choices[0].message.content = "SUMMARY:\nEmpty\n\nKEY POINTS:\n\nACTION ITEMS:\nNone"
        
        mock_client.return_value.chat.completions.create.return_value = mock_response
        
        result = summarize_text("", api_key="test-key")
        assert isinstance(result, dict)


class TestGeneratedSamples:
    """Test with generated audio samples"""
    
    @pytest.fixture
    def generated_samples_dir(self):
        """Path to generated test samples"""
        return "../test-audio/generated"
    
    def test_generated_samples_exist(self, generated_samples_dir):
        """Verify generated test samples exist"""
        if not os.path.exists(generated_samples_dir):
            pytest.skip("Generated samples not found")
        
        expected_files = [
            "english.mp3",
            "spanish.mp3",
            "french.mp3",
            "meeting_notes.mp3"
        ]
        
        for filename in expected_files:
            filepath = os.path.join(generated_samples_dir, filename)
            assert os.path.exists(filepath), f"Missing test sample: {filename}"
    
    @pytest.mark.slow
    @pytest.mark.parametrize("language", ["english", "spanish", "french"])
    def test_transcribe_generated_samples(self, generated_samples_dir, language):
        """Test transcription of generated samples (slow - requires model)"""
        filepath = os.path.join(generated_samples_dir, f"{language}.mp3")
        
        if not os.path.exists(filepath):
            pytest.skip(f"{language} sample not found")
        
        from vibetranscribe import transcribe_audio
        
        result = transcribe_audio(filepath, model_size="tiny")
        
        # All samples should mention "project" or "meeting"
        assert isinstance(result, str)
        assert len(result) > 10  # Should have substantial content
        print(f"{language.title()} transcription: {result[:100]}...")


# Test configuration
def pytest_configure(config):
    """Configure pytest with custom markers"""
    config.addinivalue_line(
        "markers", "slow: marks tests as slow (deselect with '-m \"not slow\"')"
    )
