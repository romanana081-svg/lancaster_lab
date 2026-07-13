
    SELECT
        observation.person_id,
        observation.observation_concept_id,
        o_standard_concept.concept_name as standard_concept_name,
        o_standard_concept.concept_code as standard_concept_code,
        o_standard_concept.vocabulary_id as standard_vocabulary,
        observation.observation_datetime,
        observation.observation_type_concept_id,
        o_type.concept_name as observation_type_concept_name,
        observation.value_as_number,
        observation.value_as_string,
        observation.value_as_concept_id,
        o_value.concept_name as value_as_concept_name,
        observation.qualifier_concept_id,
        o_qualifier.concept_name as qualifier_concept_name,
        observation.unit_concept_id,
        o_unit.concept_name as unit_concept_name,
        observation.visit_occurrence_id,
        o_visit.concept_name as visit_occurrence_concept_name,
        observation.observation_source_value,
        observation.observation_source_concept_id,
        o_source_concept.concept_name as source_concept_name,
        o_source_concept.concept_code as source_concept_code,
        o_source_concept.vocabulary_id as source_vocabulary,
        observation.unit_source_value,
        observation.qualifier_source_value,
        observation.value_source_concept_id,
        observation.value_source_value,
        observation.questionnaire_response_id 
    FROM
        ( SELECT
            * 
        FROM
            `observation` observation 
        WHERE
            (
                observation_source_concept_id IN (37202301)
            )  
            AND (
                observation.PERSON_ID IN (SELECT
                    distinct person_id  
                FROM
                    `cb_search_person` cb_search_person  
                WHERE
                    cb_search_person.person_id IN (SELECT
                        person_id 
                    FROM
                        `cb_search_person` p 
                    WHERE
                        has_whole_genome_variant = 1 ) )
            )) observation 
    LEFT JOIN
        `concept` o_standard_concept 
            ON observation.observation_concept_id = o_standard_concept.concept_id 
    LEFT JOIN
        `concept` o_type 
            ON observation.observation_type_concept_id = o_type.concept_id 
    LEFT JOIN
        `concept` o_value 
            ON observation.value_as_concept_id = o_value.concept_id 
    LEFT JOIN
        `concept` o_qualifier 
            ON observation.qualifier_concept_id = o_qualifier.concept_id 
    LEFT JOIN
        `concept` o_unit 
            ON observation.unit_concept_id = o_unit.concept_id 
    LEFT JOIN
        `visit_occurrence` v 
            ON observation.visit_occurrence_id = v.visit_occurrence_id 
    LEFT JOIN
        `concept` o_visit 
            ON v.visit_concept_id = o_visit.concept_id 
    LEFT JOIN
        `concept` o_source_concept 
            ON observation.observation_source_concept_id = o_source_concept.concept_id