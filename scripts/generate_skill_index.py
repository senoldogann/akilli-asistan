import os
import shutil

# Define the skills directory
SKILLS_DIR = ".agent/skills"
MAIN_INDEX = os.path.join(SKILLS_DIR, "SKILL_INDEX.md")

print(f"Generating hierarchical index for {SKILLS_DIR}...")

def extract_desc(skill_path):
    desc = "No description found."
    skill_md = os.path.join(skill_path, "SKILL.md")
    if os.path.exists(skill_md):
        try:
            with open(skill_md, "r", encoding="utf-8") as f:
                content = f.read()
                if content.startswith("---"):
                    parts = content.split("---", 2)
                    if len(parts) >= 3:
                        frontmatter = parts[1]
                        for line in frontmatter.split("\n"):
                            if line.strip().startswith("description:"):
                                desc = line.split(":", 1)[1].strip()
                                break
        except: pass
    return desc

# Collect all skills
all_skills = []
try:
    for item in os.listdir(SKILLS_DIR):
        item_path = os.path.join(SKILLS_DIR, item)
        if os.path.isdir(item_path) and not item.startswith(".") and item != "docs":
            desc = extract_desc(item_path)
            all_skills.append((item, desc))
    
    all_skills.sort()
    
    # Group by first letter
    groups = {}
    for name, desc in all_skills:
        letter = name[0].upper()
        if not letter.isalpha(): letter = "#"
        if letter not in groups: groups[letter] = []
        groups[letter].append((name, desc))
    
    # 1. Clear old sub-indexes
    for f in os.listdir(SKILLS_DIR):
        if f.startswith("SKILL_INDEX_") and f.endswith(".md"):
            os.remove(os.path.join(SKILLS_DIR, f))

    # 2. Create sub-indexes
    sorted_letters = sorted(groups.keys())
    for letter in sorted_letters:
        sub_file = os.path.join(SKILLS_DIR, f"SKILL_INDEX_{letter}.md")
        with open(sub_file, "w", encoding="utf-8") as f:
            f.write(f"# 🧠 Skills Index - {letter}\n\n")
            f.write("| Skill | Description |\n|-------|-------------|\n")
            for name, desc in groups[letter]:
                safe_desc = desc.replace('|', '\\|')
                f.write(f"| `@{name}` | {safe_desc} |\n")
    
    # 3. Create main index
    with open(MAIN_INDEX, "w", encoding="utf-8") as f:
        f.write("# 🧠 Master Skill Index (Hierarchical)\n\n")
        f.write(f"> **Total Skills:** {len(all_skills)}\n\n")
        f.write("To minimize memory usage, skills are grouped alphabetically. **Click a letter to view skills:**\n\n")
        
        # Grid layout for letters
        f.write("| " + " | ".join(sorted_letters) + " |\n")
        f.write("| " + " | ".join(["---"] * len(sorted_letters)) + " |\n")
        links = [f"[View {l}](file:///{SKILLS_DIR}/SKILL_INDEX_{l}.md)" for l in sorted_letters]
        f.write("| " + " | ".join(links) + " |\n\n")
        
        f.write("## 🛠️ Usage\n")
        f.write("When you need a specific capability, find it in the alphabetical list and mention it as `@skill-name`.\n")

    print(f"✅ Successfully generated {len(sorted_letters)} sub-indexes and 1 master index.")

except Exception as e:
    print(f"❌ Error: {e}")
