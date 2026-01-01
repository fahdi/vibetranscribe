"""
Summarization module using OpenAI API
"""

import os
from openai import OpenAI

def summarize_text(text: str, length: str = "short", api_key: str = None) -> dict:
    """
    Summarize transcribed text using OpenAI
    
    Args:
        text: The transcribed text to summarize
        length: Summary length - 'short', 'medium', or 'long'
        api_key: OpenAI API key (or set OPENAI_API_KEY env var)
    
    Returns:
        dict with 'summary', 'key_points', and 'action_items'
    """
    
    # Get API key from parameter or environment
    api_key = api_key or os.getenv("OPENAI_API_KEY")
    if not api_key:
        raise ValueError(
            "OpenAI API key required. Set OPENAI_API_KEY environment variable or pass api_key parameter."
        )
    
    client = OpenAI(api_key=api_key)
    
    # Define prompts based on length
    length_instructions = {
        "short": "1-2 sentences maximum",
        "medium": "3-5 sentences",
        "long": "A detailed paragraph"
    }
    
    instruction = length_instructions.get(length, length_instructions["short"])
    
    prompt = f"""You are a helpful assistant that summarizes transcribed audio content.

Given the following transcription, provide:
1. A concise summary ({instruction})
2. Key points (bullet list, max 5 items)
3. Action items if any are mentioned (bullet list, or "None" if no actions)

Transcription:
{text}

Format your response as:
SUMMARY:
[your summary here]

KEY POINTS:
- [point 1]
- [point 2]

ACTION ITEMS:
- [action 1]
- [action 2]
(or "None" if no actions)"""

    try:
        response = client.chat.completions.create(
            model="gpt-4o-mini",  # Fast and cost-effective
            messages=[
                {"role": "system", "content": "You are a helpful assistant that creates clear, concise summaries."},
                {"role": "user", "content": prompt}
            ],
            temperature=0.3,  # More focused, less creative
            max_tokens=500
        )
        
        result = response.choices[0].message.content
        
        # Parse the response
        summary = ""
        key_points = []
        action_items = []
        
        current_section = None
        for line in result.split('\n'):
            line = line.strip()
            if not line:
                continue
                
            if line.startswith('SUMMARY:'):
                current_section = 'summary'
                continue
            elif line.startswith('KEY POINTS:'):
                current_section = 'key_points'
                continue
            elif line.startswith('ACTION ITEMS:'):
                current_section = 'action_items'
                continue
            
            if current_section == 'summary':
                summary += line + " "
            elif current_section == 'key_points' and line.startswith('-'):
                key_points.append(line[1:].strip())
            elif current_section == 'action_items' and line.startswith('-'):
                action_items.append(line[1:].strip())
            elif current_section == 'action_items' and line.lower() == 'none':
                action_items = []
        
        return {
            "summary": summary.strip(),
            "key_points": key_points,
            "action_items": action_items
        }
        
    except Exception as e:
        raise Exception(f"OpenAI API error: {e}")


def format_summary_output(summary_data: dict, format_type: str = "text") -> str:
    """
    Format summary data for output
    
    Args:
        summary_data: Dict with summary, key_points, action_items
        format_type: 'text' or 'markdown'
    
    Returns:
        Formatted string
    """
    if format_type == "markdown":
        output = f"# Summary\n\n{summary_data['summary']}\n\n"
        
        if summary_data['key_points']:
            output += "## Key Points\n\n"
            for point in summary_data['key_points']:
                output += f"- {point}\n"
            output += "\n"
        
        if summary_data['action_items']:
            output += "## Action Items\n\n"
            for item in summary_data['action_items']:
                output += f"- [ ] {item}\n"
        
        return output
    else:
        # Plain text format
        output = f"SUMMARY:\n{summary_data['summary']}\n\n"
        
        if summary_data['key_points']:
            output += "KEY POINTS:\n"
            for point in summary_data['key_points']:
                output += f"  • {point}\n"
            output += "\n"
        
        if summary_data['action_items']:
            output += "ACTION ITEMS:\n"
            for item in summary_data['action_items']:
                output += f"  ☐ {item}\n"
        
        return output
