
    SELECT
        c_occurrence.person_id,
        c_occurrence.condition_concept_id,
        c_standard_concept.concept_name as standard_concept_name,
        c_standard_concept.concept_code as standard_concept_code,
        c_standard_concept.vocabulary_id as standard_vocabulary,
        c_occurrence.condition_start_datetime,
        c_occurrence.condition_end_datetime,
        c_occurrence.condition_type_concept_id,
        c_type.concept_name as condition_type_concept_name,
        c_occurrence.stop_reason,
        c_occurrence.visit_occurrence_id,
        visit.concept_name as visit_occurrence_concept_name,
        c_occurrence.condition_source_value,
        c_occurrence.condition_source_concept_id,
        c_source_concept.concept_name as source_concept_name,
        c_source_concept.concept_code as source_concept_code,
        c_source_concept.vocabulary_id as source_vocabulary,
        c_occurrence.condition_status_source_value,
        c_occurrence.condition_status_concept_id,
        c_status.concept_name as condition_status_concept_name 
    FROM
        ( SELECT
            * 
        FROM
            `condition_occurrence` c_occurrence 
        WHERE
            (
                condition_concept_id IN (SELECT
                    DISTINCT c.concept_id 
                FROM
                    `cb_criteria` c 
                JOIN
                    (SELECT
                        CAST(cr.id as string) AS id       
                    FROM
                        `cb_criteria` cr       
                    WHERE
                        concept_id IN (317309, 3654996)       
                        AND full_text LIKE '%_rank1]%'      ) a 
                        ON (c.path LIKE CONCAT('%.', a.id, '.%') 
                        OR c.path LIKE CONCAT('%.', a.id) 
                        OR c.path LIKE CONCAT(a.id, '.%') 
                        OR c.path = a.id) 
                WHERE
                    is_standard = 1 
                    AND is_selectable = 1)
            )  
            AND (
                c_occurrence.PERSON_ID IN (SELECT
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
            )) c_occurrence 
    LEFT JOIN
        `concept` c_standard_concept 
            ON c_occurrence.condition_concept_id = c_standard_concept.concept_id 
    LEFT JOIN
        `concept` c_type 
            ON c_occurrence.condition_type_concept_id = c_type.concept_id 
    LEFT JOIN
        `visit_occurrence` v 
            ON c_occurrence.visit_occurrence_id = v.visit_occurrence_id 
    LEFT JOIN
        `concept` visit 
            ON v.visit_concept_id = visit.concept_id 
    LEFT JOIN
        `concept` c_source_concept 
            ON c_occurrence.condition_source_concept_id = c_source_concept.concept_id 
    LEFT JOIN
        `concept` c_status 
            ON c_occurrence.condition_status_concept_id = c_status.concept_id