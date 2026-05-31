"use server";

import OpenAI from "openai";

const OPENAI_API_KEY = process.env.OPENAI_API_KEY;
if (!OPENAI_API_KEY) {
    throw new Error('OPENAI_API_KEY environment variable is not set');
}

const openai = new OpenAI({
    apiKey: OPENAI_API_KEY,
});

export interface VideoEvent {
    timestamp: string;
    description: string;
    isDangerous: boolean;
}

export interface PoseKeypoint {
    x: number;
    y: number;
    score?: number;
    name?: string;
}

export interface TensorFlowData {
    poseKeypoints: PoseKeypoint[];
    faceDetected: boolean;
    faceConfidence?: number;
}

export async function detectEvents(
    base64Image: string, 
    transcript: string = '',
    tensorflowData?: TensorFlowData
): Promise<{ events: VideoEvent[], rawResponse: string }> {
    console.log('Starting frame analysis with OpenAI Vision...');
    try {
        if (!base64Image) {
            throw new Error("No image data provided");
        }

        // Ensure proper data URL format
        let imageUrl = base64Image;
        if (!imageUrl.startsWith('data:')) {
            imageUrl = `data:image/jpeg;base64,${base64Image}`;
        }

        // Build TensorFlow context for enhanced analysis
        let tensorflowContext = '';
        if (tensorflowData) {
            const { poseKeypoints, faceDetected, faceConfidence } = tensorflowData;
            
            if (faceDetected) {
                tensorflowContext += `\nFace Detection: A face was detected with ${faceConfidence ? Math.round(faceConfidence * 100) + '% confidence' : 'high confidence'}.`;
            } else {
                tensorflowContext += `\nFace Detection: No face is clearly visible (person may be turned away, fallen, or obscured).`;
            }
            
            if (poseKeypoints && poseKeypoints.length > 0) {
                // Analyze pose for potential issues
                const visibleKeypoints = poseKeypoints.filter(kp => (kp.score || 0) > 0.3);
                const keypointNames = visibleKeypoints.map(kp => kp.name).filter(Boolean);
                
                tensorflowContext += `\nPose Detection: ${visibleKeypoints.length} body keypoints detected (${keypointNames.join(', ')}).`;
                
                // Check for abnormal poses (low position could indicate fall)
                const avgY = visibleKeypoints.reduce((sum, kp) => sum + kp.y, 0) / visibleKeypoints.length;
                if (avgY > 300) { // Lower in frame typically means person is on ground
                    tensorflowContext += ` The person's body position appears LOW in the frame, which may indicate lying down, fallen, or slumped position.`;
                }
                
                // Check if key body parts are missing (could indicate occlusion or fall)
                const hasHead = keypointNames.some(n => n?.includes('nose') || n?.includes('eye') || n?.includes('ear'));
                const hasShoulders = keypointNames.some(n => n?.includes('shoulder'));
                if (!hasHead && hasShoulders) {
                    tensorflowContext += ` Head/face keypoints are NOT visible but body is detected - person may be face-down or head is obscured.`;
                }
            }
        }

        console.log('Sending image to OpenAI Vision...', { hasTensorflowData: !!tensorflowData });
        
        const prompt = `Analyze this frame and determine if any of these specific dangerous situations are occurring:

1. Medical Emergencies:
- Person unconscious or lying motionless
- Person clutching chest/showing signs of heart problems
- Seizures or convulsions
- Difficulty breathing or choking

2. Falls and Injuries:
- Person falling or about to fall
- Person on the ground after a fall
- Signs of injury or bleeding
- Limping or showing signs of physical trauma

3. Distress Signals:
- Person calling for help or showing distress
- Panic attacks or severe anxiety symptoms
- Signs of fainting or dizziness
- Headache or unease
- Signs of unconsciousness

4. Violence or Threats:
- Physical altercations
- Threatening behavior
- Weapons visible

5. Suspicious Activities:
- Shoplifting
- Vandalism
- Trespassing
${tensorflowContext ? `
TENSORFLOW ML DETECTION DATA (use this to enhance your analysis):
${tensorflowContext}
` : ''}${transcript ? `
AUDIO TRANSCRIPT from the scene: "${transcript}"
` : ''}
Return ONLY a JSON object in this exact format (no markdown, no code blocks):

{
    "events": [
        {
            "timestamp": "00:00",
            "description": "Brief description of what's happening in this frame",
            "isDangerous": true or false
        }
    ]
}`;

        try {
            const response = await openai.chat.completions.create({
                model: "gpt-4o-mini", // Cost-effective vision model with good rate limits
                messages: [
                    {
                        role: "user",
                        content: [
                            {
                                type: "text",
                                text: prompt
                            },
                            {
                                type: "image_url",
                                image_url: {
                                    url: imageUrl,
                                    detail: "low" // Use low detail for faster processing and lower cost
                                }
                            }
                        ]
                    }
                ],
                max_tokens: 500,
                temperature: 0.3 // Lower temperature for more consistent outputs
            });

            const text = response.choices[0]?.message?.content || '';
            console.log('Raw OpenAI Response:', text);

            // Try to extract JSON from the response, handling potential code blocks
            let jsonStr = text;
            
            // First try to extract content from code blocks if present
            const codeBlockMatch = text.match(/```(?:json)?\s*({[\s\S]*?})\s*```/);
            if (codeBlockMatch) {
                jsonStr = codeBlockMatch[1];
                console.log('Extracted JSON from code block:', jsonStr);
            } else {
                // If no code block, try to find raw JSON
                const jsonMatch = text.match(/\{[^]*\}/);  
                if (jsonMatch) {
                    jsonStr = jsonMatch[0];
                    console.log('Extracted raw JSON:', jsonStr);
                }
            }

            try {
                const parsed = JSON.parse(jsonStr);
                return {
                    events: parsed.events || [],
                    rawResponse: text
                };
            } catch (parseError) {
                console.error('Error parsing JSON:', parseError);
                return { events: [], rawResponse: text };
            }

        } catch (error) {
            console.error('Error calling OpenAI API:', error);
            return { events: [], rawResponse: String(error) };
        }
    } catch (error) {
        console.error('Error in detectEvents:', error);
        return { events: [], rawResponse: String(error) };
    }
}
